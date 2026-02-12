#!/usr/bin/env php
<?php

/**
 * Log status line events to ~/.claude/logs/status_line.json.
 *
 * @param array $input_data The input data from Claude Code
 * @param string $status_line_output The generated status line
 * @param string|null $error_message Optional error message to log
 */
function log_status_line($input_data, $status_line_output, $error_message = null) {
    // Ensure ~/.claude/logs directory exists
    $log_dir = $_SERVER['HOME'] . '/.claude/logs';
    if (!is_dir($log_dir)) {
        mkdir($log_dir, 0755, true);
    }

    $log_file = $log_dir . '/status_line.jsonl';

    // Rolling trim: keep last 500 entries when file exceeds 2MB
    if (file_exists($log_file) && filesize($log_file) > 2 * 1024 * 1024) {
        $lines = file($log_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        $kept = array_slice($lines, -500);
        file_put_contents($log_file, implode("\n", $kept) . "\n", LOCK_EX);
    }

    // Create log entry
    $log_entry = [
        'timestamp' => date('c'),
        'version' => 'php',
        'input_data' => $input_data,
        'status_line_output' => $status_line_output
    ];

    if ($error_message) {
        $log_entry['error'] = $error_message;
    }

    // Append single JSON line (O(1) memory, no read required)
    file_put_contents($log_file, json_encode($log_entry) . "\n", FILE_APPEND | LOCK_EX);
}

/**
 * Get the current git branch name.
 *
 * @return string|null The branch name or null if not in a git repo
 */
function get_git_branch() {
    $output = null;
    $return_var = null;
    exec('git rev-parse --abbrev-ref HEAD 2>/dev/null', $output, $return_var);

    if ($return_var === 0 && !empty($output)) {
        return trim($output[0]);
    }

    return null;
}

/**
 * Get git status indicator showing number of changed files.
 *
 * @return string Empty string or ±N format where N is number of changes
 */
function get_git_status() {
    $output = null;
    $return_var = null;
    exec('git status --porcelain 2>/dev/null', $output, $return_var);

    if ($return_var === 0 && !empty($output)) {
        return '±' . count($output);
    }

    return '';
}

/**
 * Get context usage from transcript file.
 *
 * @param string $transcript_path Path to the session transcript JSONL file
 * @param int $max_context Maximum context window size
 * @return array [context_length, percentage] where context_length is total tokens used
 */
function get_context_usage($transcript_path, $max_context) {
    $baseline = 20000; // System prompt (~3k) + tools (~15k) + memory + overhead

    if (!file_exists($transcript_path)) {
        $pct = (int)(($baseline * 100) / $max_context);
        return [$baseline, $pct, true]; // true = estimate
    }

    $last_usage = null;
    $handle = fopen($transcript_path, 'r');
    if (!$handle) {
        $pct = (int)(($baseline * 100) / $max_context);
        return [$baseline, $pct, true];
    }

    while (($line = fgets($handle)) !== false) {
        $entry = json_decode($line, true);
        if ($entry === null) continue;

        // Skip sidechain and error messages
        if (!empty($entry['isSidechain']) || !empty($entry['isApiErrorMessage'])) {
            continue;
        }

        // Look for messages with usage data
        if (isset($entry['message']['usage'])) {
            $last_usage = $entry['message']['usage'];
        }
    }
    fclose($handle);

    if ($last_usage) {
        $context_length = ($last_usage['input_tokens'] ?? 0)
            + ($last_usage['cache_read_input_tokens'] ?? 0)
            + ($last_usage['cache_creation_input_tokens'] ?? 0);
        $pct = (int)(($context_length * 100) / $max_context);
        $pct = min($pct, 100);
        return [$context_length, $pct, false];
    }

    $pct = (int)(($baseline * 100) / $max_context);
    return [$baseline, $pct, true];
}

/**
 * Generate a visual context bar.
 *
 * @param int $percentage Context usage percentage (0-100)
 * @param bool $is_estimate Whether this is an estimate
 * @param int $max_k Max context in thousands
 * @return string Formatted context bar with colors
 */
function get_context_bar($percentage, $is_estimate, $max_k) {
    $bar_width = 10;
    $bar = '';

    // Color codes
    $c_accent = "\033[38;5;74m";   // blue
    $c_empty = "\033[38;5;238m";   // dark gray
    $c_reset = "\033[0m";

    for ($i = 0; $i < $bar_width; $i++) {
        $bar_start = $i * 10;
        $progress = $percentage - $bar_start;

        if ($progress >= 8) {
            $bar .= $c_accent . '█' . $c_reset;
        } elseif ($progress >= 3) {
            $bar .= $c_accent . '▄' . $c_reset;
        } else {
            $bar .= $c_empty . '░' . $c_reset;
        }
    }

    $prefix = $is_estimate ? '~' : '';
    return $bar . ' ' . getMsg("{$prefix}{$percentage}% of {$max_k}k", 'dark_gray');
}

/**
 * Get recent prompts from transcript file.
 *
 * @param string $transcript_path Path to the session transcript JSONL file
 * @param int $count Maximum number of prompts to return (default 3)
 * @return array [prompts_array, error_message] where prompts are in reverse chronological order
 */
function get_prompts($transcript_path, $count = 3) {
    if (!file_exists($transcript_path)) {
        return [[], "Transcript file does not exist"];
    }

    $prompts = [];
    $handle = fopen($transcript_path, 'r');
    if (!$handle) {
        return [[], "Could not open transcript file"];
    }

    while (($line = fgets($handle)) !== false) {
        $entry = json_decode($line, true);
        if ($entry === null) continue;

        // Look for user messages with text content
        if (($entry['type'] ?? '') === 'user') {
            $content = $entry['message']['content'] ?? [];
            if (is_array($content) && !empty($content)) {
                $first = $content[0];
                if (is_array($first) && ($first['type'] ?? '') === 'text' && isset($first['text'])) {
                    $prompts[] = $first['text'];
                }
            }
        }
    }
    fclose($handle);

    if (!empty($prompts)) {
        $recent_prompts = array_slice($prompts, -$count);
        return [array_reverse($recent_prompts), null];
    }

    return [[], "No prompts in transcript"];
}

/**
 * Generate the complete status line with model, directory, git, and prompt info.
 *
 * @param array $input_data Input data from Claude Code containing session and workspace info
 * @return string Formatted status line with ANSI color codes
 */
function generate_status_line($input_data) {
    $parts = [];

    // Model display name
    $model_info = $input_data['model'] ?? [];
    $model_name = $model_info['display_name'] ?? 'Claude';
    $parts[] = getMsg("[{$model_name}]", 'cyan');

    // Current directory
    $workspace = $input_data['workspace'] ?? [];
    $current_dir = $workspace['current_dir'] ?? '';
    if ($current_dir) {
        $dir_name = basename($current_dir);
        $parts[] = getMsg('📁 ', 'blue') . getMsg('/', 'dark_gray') . getMsg($dir_name, 'blue');
    }

    // Git branch and status
    $git_branch = get_git_branch();
    if ($git_branch) {
        $git_status = get_git_status();
        $git_info = "🌿 {$git_branch}";
        if ($git_status) {
            $git_info .= " {$git_status}";
        }
        $parts[] = getMsg($git_info, 'green');
    }

    // Context bar
    $transcript_path = $input_data['transcript_path'] ?? '';
    $max_context = $input_data['context_window']['context_window_size'] ?? 200000;
    $max_k = (int)($max_context / 1000);
    list($context_length, $pct, $is_estimate) = get_context_usage($transcript_path, $max_context);
    $parts[] = get_context_bar($pct, $is_estimate, $max_k);

    // Recent prompts
    list($prompts, $error) = get_prompts($transcript_path, 3);

    if ($error || empty($prompts)) {
        // Show fallback message
        $parts[] = getMsg('💭 No recent prompts', 'dark_gray');
    } else {
        // Process each prompt with different opacity/colors
        foreach ($prompts as $index => $prompt) {
            // Format the prompt for status line
            $prompt = preg_replace('/\s+/', ' ', trim($prompt));

            // Different truncation lengths for different positions
            $max_lengths = [60, 35, 25]; // Current, previous, older
            $max_length = $max_lengths[$index] ?? 30;

            if (strlen($prompt) > $max_length) {
                $prompt = substr($prompt, 0, $max_length - 3) . '...';
            }

            if ($index === 0) {
                // Current prompt - full brightness with icon
                $prompt_lower = strtolower($prompt);
                if (strpos($prompt, '/') === 0) {
                    $prompt_color = 'yellow';
                    $icon = "⚡";
                } elseif (strpos($prompt, '?') !== false) {
                    $prompt_color = 'blue';
                    $icon = "❓";
                } elseif (preg_match('/\b(create|write|add|implement|build)\b/', $prompt_lower)) {
                    $prompt_color = 'light_green';
                    $icon = "💡";
                } elseif (preg_match('/\b(fix|debug|error|issue)\b/', $prompt_lower)) {
                    $prompt_color = 'red';
                    $icon = "🐛";
                } elseif (preg_match('/\b(refactor|improve|optimize)\b/', $prompt_lower)) {
                    $prompt_color = 'magenta';
                    $icon = "♻️";
                } else {
                    $prompt_color = 'white';
                    $icon = "💬";
                }
                $parts[] = $icon . ' ' . getMsg($prompt, $prompt_color);
            } elseif ($index === 1) {
                // Previous prompt - light gray
                $parts[] = getMsg($prompt, 'light_gray');
            } else {
                // Older prompt - dark gray
                $parts[] = getMsg($prompt, 'dark_gray');
            }
        }
    }

    return implode(' | ', $parts);
}

/**
 * Format text with optional color.
 *
 * @param string $text The text to format
 * @param string $color Color name from the color() function palette
 * @return string Formatted text with ANSI color codes
 */
function getMsg($text, $color = '') {
    if ($color) {
        $text = color($color) . $text . color('none');
    }

    return $text;
}

/**
 * Get a cli-formatted color indicator.
 *
 * @since  1.0.0
 *
 * @param  string $color Color to get.
 *
 * @return string
 */
function color($color) {
    $colors = [
        'red_bg'        => "\e[1;37;41m",
        'none'          => "\033[0m",
        'default'       => "\033[39m",
        'black'         => "\033[30m",
        'red'           => "\033[31m",
        'green'         => "\033[32m",
        'yellow'        => "\033[33m",
        'blue'          => "\033[34m",
        'magenta'       => "\033[35m",
        'cyan'          => "\033[36m",
        'light_gray'    => "\033[37m",
        'dark_gray'     => "\033[90m",
        'light_red'     => "\033[91m",
        'light_green'   => "\033[92m",
        'light_yellow'  => "\033[93m",
        'light_blue'    => "\033[94m",
        'light_magenta' => "\033[95m",
        'light_cyan'    => "\033[96m",
        'white'         => "\033[97m",
    ];

    return $color && isset($colors[$color])
        ? $colors[$color]
        : '';
}

/**
 * Main function that reads JSON from stdin and outputs formatted status line.
 */
function main() {
    try {
        // Read JSON input from stdin
        $input = stream_get_contents(STDIN);
        $input_data = json_decode($input, true);

        if ($input_data === null) {
            echo getMsg("💭 JSON decode error", 'red') . "\n";
            exit(0);
        }

        // Generate status line
        $status_line = generate_status_line($input_data);

        // Log the status line event
        log_status_line($input_data, $status_line);

        // Output the status line
        echo $status_line . "\n";

        exit(0);

    } catch (Exception $e) {
        // Handle any errors gracefully
        echo getMsg("💭 Error: " . $e->getMessage(), 'red') . "\n";
        exit(0);
    }
}

main();
?>