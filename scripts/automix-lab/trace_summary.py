#!/usr/bin/env python3
"""Tabulates why Music's transition planner accepted or rejected each strategy.

  trace_summary.py <harvest.jsonl>...

Reads the `trace` field harvest.py records for each pair and counts, per strategy, the planner's
own stated outcome ("Not applicable. Genres not compatible", "Styling results identified", ...),
then how the final choice was made among the strategies that produced a result.
"""
import collections, json, re, sys

ORDER = ["Beat-Matched Dance", "Beat-Matched Hip-Hop", "Beat-Matched Pop", "Beat-Matched Filtered Cross-Fade",
         "Smart Cross-Fade", "Dead-Air Removal", "Soft Skip", "Fallback Cross-Fade"]

def outcomes(trace):
    """The last verdict the planner logged for each strategy, with the check that failed just before it."""
    found, previous = {}, ""
    for line in trace:
        name, _, rest = line.partition(": ")
        if name in ORDER:
            if rest.startswith(("Not applicable.", "No candidate result.")):
                reason = rest.split(". ", 1)[1].rstrip(".")
                if "ncompatible" in previous or "False" in previous:
                    reason += " <- " + re.sub(r"-?\d+(\.\d+)?", "#", previous)[:90]
                found[name] = reason
            elif rest.startswith("Styling results identified"):
                found[name] = "RESULT"
            elif rest.startswith("No styling results identified"):
                found.setdefault(name, "no result")
            previous = ""
        elif not line.startswith(("Outgoing placement", "Incoming placement", "Placement")):
            previous = line
    return found

def main():
    per_strategy = {name: collections.Counter() for name in ORDER}
    selection = collections.Counter()
    pairs = 0
    for path in sys.argv[1:]:
        for row in open(path):
            record = json.loads(row)
            trace = record.get("trace") or []
            if not trace:
                continue
            pairs += 1
            for name, reason in outcomes(trace).items():
                per_strategy[name][reason] += 1
            preferred = next((t for t in trace if t.startswith("Preferred results:")), "Preferred results: none")
            chosen = next((t for t in trace if t.startswith("Selected result:")), "Selected result: none")
            selection[(record["plan"].get("strategy", "none").split(" - ")[0],
                       preferred.split(": ", 1)[1][:60], re.sub(r"\d+", "#", chosen.split(": ", 1)[1])[:50])] += 1
    print(f"{pairs} pairs with a trace")
    for name in ORDER:
        print(f"\n{name}")
        for reason, count in per_strategy[name].most_common(12):
            print(f"  {count:5d}  {reason[:170]}")
    print("\nFinal choice (strategy | preferred set | how selected)")
    for key, count in selection.most_common(20):
        print(f"  {count:5d}  {' | '.join(key)}")

if __name__ == "__main__":
    main()
