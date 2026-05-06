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
    $bar_width = 15;
    $bar = '';

    // Color codes
    $c_accent = "\033[38;5;74m";   // blue
    $c_empty = "\033[38;5;238m";   // dark gray
    $c_reset = "\033[0m";

    for ($i = 0; $i < $bar_width; $i++) {
        $bar_start = $i * (100 / $bar_width);
        $progress = $percentage - $bar_start;

        if ($progress >= 5.3) {
            $bar .= $c_accent . '█' . $c_reset;
        } elseif ($progress >= 2) {
            $bar .= $c_accent . '▄' . $c_reset;
        } else {
            $bar .= $c_empty . '░' . $c_reset;
        }
    }

    $prefix = $is_estimate ? '~' : '';
    return $bar . ' ' . getMsg("{$prefix}{$percentage}% of {$max_k}k", 'dark_gray');
}

/**
 * Generate a visual rate limit bar with optional timeline marker.
 *
 * @param string $label Display label (e.g. '5h', '7d')
 * @param int $percentage Usage percentage (0-100)
 * @param int|null $resets_at Unix timestamp when this window resets
 * @param int $window_seconds Duration of the rate limit window in seconds
 * @return string Formatted rate limit bar with colors
 */
function get_rate_limit_bar($label, $percentage, $resets_at = null, $window_seconds = 0) {
    $bar_width = 15;

    $c_accent = "\033[38;5;74m";   // blue
    $c_empty = "\033[38;5;238m";   // dark gray
    $c_marker = "\033[38;5;220m";  // yellow
    $c_reset = "\033[0m";

    // Calculate timeline position (which bar cell the "now" marker falls in)
    $marker_cell = -1;
    if ($resets_at && $window_seconds > 0) {
        $remaining = $resets_at - time();
        $elapsed = $window_seconds - $remaining;
        if ($elapsed >= 0 && $elapsed <= $window_seconds) {
            $time_pct = ($elapsed / $window_seconds) * 100;
            $marker_cell = (int)($time_pct * $bar_width / 100);
            if ($marker_cell >= $bar_width) {
                $marker_cell = $bar_width - 1;
            }
        }
    }

    $bar = '';
    for ($i = 0; $i < $bar_width; $i++) {
        if ($i === $marker_cell) {
            $bar .= $c_marker . '│' . $c_reset;
            continue;
        }

        $bar_start = $i * (100 / $bar_width);
        $progress = $percentage - $bar_start;

        if ($progress >= 5.3) {
            $bar .= $c_accent . '█' . $c_reset;
        } elseif ($progress >= 2) {
            $bar .= $c_accent . '▄' . $c_reset;
        } else {
            $bar .= $c_empty . '░' . $c_reset;
        }
    }

    return getMsg($label . ': ', 'dark_gray') . $bar . ' ' . getMsg("{$percentage}%", 'dark_gray');
}

/**
 * Get the last N messages (user + assistant) from transcript file.
 *
 * @param string $transcript_path Path to the session transcript JSONL file
 * @param int $count Maximum number of messages to return
 * @return array Array of ['role' => 'user'|'assistant', 'text' => string]
 */
function get_recent_messages($transcript_path, $count = 5) {
    if (!file_exists($transcript_path)) {
        return [];
    }

    $handle = fopen($transcript_path, 'r');
    if (!$handle) {
        return [];
    }

    $messages = [];
    while (($line = fgets($handle)) !== false) {
        $entry = json_decode($line, true);
        if ($entry === null) continue;
        if (!empty($entry['isSidechain']) || !empty($entry['isApiErrorMessage'])) continue;

        $type = $entry['type'] ?? '';
        if ($type === 'user') {
            $content = $entry['message']['content'] ?? [];
            $text = '';
            if (is_array($content)) {
                foreach ($content as $block) {
                    if (is_array($block) && ($block['type'] ?? '') === 'text') {
                        $text = $block['text'];
                        break;
                    }
                }
            } elseif (is_string($content)) {
                $text = $content;
            }
            if ($text && strpos($text, '<') !== 0) {
                $messages[] = ['role' => 'user', 'text' => $text];
            }
        } elseif ($type === 'assistant') {
            $content = $entry['message']['content'] ?? [];
            if (is_array($content)) {
                foreach ($content as $block) {
                    if (is_array($block) && ($block['type'] ?? '') === 'text' && !empty($block['text'])) {
                        $messages[] = ['role' => 'assistant', 'text' => $block['text']];
                        break;
                    }
                }
            }
        }
    }
    fclose($handle);

    return array_slice($messages, -$count);
}

/**
 * Compute a stable cache key from a set of messages.
 *
 * @param array $messages Array of ['role', 'text'] pairs
 * @return string MD5 hash of concatenated role:text pairs
 */
function messages_hash($messages) {
    $parts = array_map(fn($m) => $m['role'] . ':' . $m['text'], $messages);
    return md5(implode('|', $parts));
}

/**
 * Read a cached summary for the given hash.
 *
 * @param string $hash Cache key
 * @return string|null Cached summary or null on miss
 */
function get_cached_summary($hash) {
    $file = $_SERVER['HOME'] . '/.claude/logs/ws-summary-' . $hash . '.txt';
    if (file_exists($file)) {
        return trim(file_get_contents($file)) ?: null;
    }
    return null;
}

/**
 * Write a summary to cache and prune old cache files (keep 20 most recent).
 *
 * @param string $hash Cache key
 * @param string $summary Summary text
 */
function save_summary_cache($hash, $summary) {
    $log_dir = $_SERVER['HOME'] . '/.claude/logs';
    if (!is_dir($log_dir)) {
        mkdir($log_dir, 0755, true);
    }

    $file = $log_dir . '/ws-summary-' . $hash . '.txt';
    file_put_contents($file, $summary, LOCK_EX);

    // Prune: keep only the 20 most recently modified cache files
    $pattern = $log_dir . '/ws-summary-*.txt';
    $files = glob($pattern);
    if ($files && count($files) > 20) {
        usort($files, fn($a, $b) => filemtime($a) - filemtime($b));
        $to_delete = array_slice($files, 0, count($files) - 20);
        foreach ($to_delete as $old) {
            @unlink($old);
        }
    }
}

/**
 * Generate a one-line summary of recent messages via Ollama.
 *
 * @param array $messages Array of ['role', 'text'] pairs
 * @param string $model Ollama model name
 * @return string|null Generated summary or null on failure
 */
function generate_summary_via_ollama($messages, $model) {
    $excerpt = '';
    foreach ($messages as $msg) {
        $role = $msg['role'] === 'user' ? 'User' : 'Claude';
        $text = preg_replace('/\s+/', ' ', trim($msg['text']));
        $text = substr($text, 0, 200);
        $excerpt .= "{$role}: {$text}\n";
    }

    $system = 'You summarize coding conversations in 8 words or fewer. Output ONLY the summary — no punctuation at the end, no quotes, no explanation.';
    $user   = "Summarize what's happening:\n\n" . trim($excerpt);

    $payload = json_encode([
        'model'    => $model,
        'stream'   => false,
        'messages' => [
            ['role' => 'system', 'content' => $system],
            ['role' => 'user',   'content' => $user],
        ],
    ]);

    $ch = curl_init('http://localhost:11434/api/chat');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_TIMEOUT        => 5,
        CURLOPT_CONNECTTIMEOUT => 2,
    ]);

    $response = curl_exec($ch);
    unset($ch);

    if (!$response) {
        return null;
    }

    $data = json_decode($response, true);
    $text = trim($data['message']['content'] ?? '');
    return $text ?: null;
}

/**
 * Get an AI-generated summary of recent conversation activity.
 * Returns cached result instantly if messages haven't changed; generates otherwise.
 *
 * @param string $transcript_path Path to the session transcript JSONL file
 * @param string $model Ollama model to use
 * @return string Summary text or fallback placeholder
 */
function get_conversation_summary($transcript_path, $model) {
    $messages = get_recent_messages($transcript_path, 5);
    if (empty($messages)) {
        return '💭 ' . getMsg('No conversation yet', 'dark_gray');
    }

    $hash = messages_hash($messages);
    $cached = get_cached_summary($hash);
    if ($cached !== null) {
        return '💭 ' . getMsg($cached, 'white');
    }

    // Generate — blocks briefly on first render after each new message
    $summary = generate_summary_via_ollama($messages, $model);
    if ($summary) {
        save_summary_cache($hash, $summary);
        return '💭 ' . getMsg($summary, 'white');
    }

    return '💭 ' . getMsg('summarizing...', 'dark_gray');
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

    // Context bar — prefer native used_percentage, fall back to transcript calculation
    $transcript_path = $input_data['transcript_path'] ?? '';
    $max_context = $input_data['context_window']['context_window_size'] ?? 200000;
    $max_k = (int)($max_context / 1000);
    if (isset($input_data['context_window']['used_percentage'])) {
        $pct = (int)$input_data['context_window']['used_percentage'];
        $is_estimate = false;
    } else {
        list(, $pct, $is_estimate) = get_context_usage($transcript_path, $max_context);
    }

    // Cost display
    if (isset($input_data['cost']['total_cost_usd'])) {
        $cost = number_format((float)$input_data['cost']['total_cost_usd'], 2);
        $parts[] = getMsg('$' . $cost, 'green');
    }

    // Ollama model: prefer config file, fall back to a small default
    $ollama_model = 'qwen2.5-coder:1.5b';
    $config_file = ($_SERVER['HOME'] ?? '') . '/.config/workspace-status/config';
    if (file_exists($config_file)) {
        $cfg = parse_ini_file($config_file) ?: [];
        if (!empty($cfg['OLLAMA_MODEL'])) {
            $ollama_model = $cfg['OLLAMA_MODEL'];
        }
    }

    // AI-generated conversation summary
    $parts[] = get_conversation_summary($transcript_path, $ollama_model);

    $line1 = implode(' | ', $parts);

    // Line 2: context bar + rate limits with visual bars
    $line2_parts = [];
    $line2_parts[] = get_context_bar($pct, $is_estimate, $max_k);

    if (isset($input_data['rate_limits']['five_hour']['used_percentage'])) {
        $resets_at = $input_data['rate_limits']['five_hour']['resets_at'] ?? null;
        $line2_parts[] = get_rate_limit_bar(
            '5h',
            (int)$input_data['rate_limits']['five_hour']['used_percentage'],
            $resets_at,
            5 * 3600
        );
    }
    if (isset($input_data['rate_limits']['seven_day']['used_percentage'])) {
        $resets_at = $input_data['rate_limits']['seven_day']['resets_at'] ?? null;
        $line2_parts[] = get_rate_limit_bar(
            '7d',
            (int)$input_data['rate_limits']['seven_day']['used_percentage'],
            $resets_at,
            7 * 86400
        );
    }

    $line1 .= "\n" . implode('  ', $line2_parts);

    return $line1;
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