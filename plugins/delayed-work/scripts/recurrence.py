"""Plan native local-clock cron entries without rounding the requested cadence."""
import argparse
import datetime
import json


def plan(when, every):
    first = datetime.datetime.fromisoformat(when)
    if first.tzinfo is None:
        raise ValueError("first fire needs an explicit UTC offset")
    if every < 60 or every % 60 or 86400 % every:
        raise ValueError("native recurrence requires whole-minute intervals dividing 24 hours")
    # First delivery is a separate one-shot. These entries preserve its local
    # minute phase each day; the harness, not a model wake, handles recurrence.
    start = first.hour * 60 + first.minute
    minutes = {}
    for offset in range(0, 1440, every // 60):
        hour, minute = divmod((start + offset) % 1440, 60)
        minutes.setdefault(minute, []).append(hour)
    groups = {}
    for minute, hours in sorted(minutes.items()):
        groups.setdefault(tuple(sorted(hours)), []).append(minute)
    expressions = [f"{','.join(map(str, values))} {','.join(map(str, hours))} * * *"
                   for hours, values in groups.items()]
    if len(expressions) > 50:
        raise ValueError("native recurrence would exceed the session's 50-job limit")
    return {"first": first.isoformat(), "every_seconds": every, "cron": expressions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--when", required=True)
    parser.add_argument("--every", required=True, type=int)
    args = parser.parse_args()
    try:
        result = plan(args.when, args.every)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
