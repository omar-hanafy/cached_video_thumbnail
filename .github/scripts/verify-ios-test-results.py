"""Fail unless XCTest ran all Dart integration and Swift cancellation tests."""

import json
import sys


def verify(summary, report):
    expected = {"ThumbnailIntegrationTests": 19, "RunnerTests": 5}
    counts = dict.fromkeys(expected, 0)
    seen = set()

    def visit(nodes, suite=None):
        for node in nodes:
            node_suite = suite
            if node["nodeType"] == "Test Suite" and node["name"] in expected:
                node_suite = node["name"]
            if node["nodeType"] == "Test Case":
                if node_suite not in counts or node.get("result") != "Passed":
                    raise ValueError(f"Unexpected or unsuccessful test: {node}")
                identity = (node_suite, node.get("nodeIdentifier", node["name"]))
                if identity in seen:
                    raise ValueError(f"Duplicate XCTest result: {identity}")
                seen.add(identity)
                counts[node_suite] += 1
            visit(node.get("children", []), node_suite)

    visit(report["testNodes"])
    if counts != expected:
        raise ValueError(f"Incomplete XCTest coverage: expected {expected}, got {counts}")
    if (
        summary["result"] != "Passed"
        or summary["totalTestCount"] != 24
        or summary["passedTests"] != 24
        or any(summary[key] != 0 for key in ("failedTests", "skippedTests", "expectedFailures"))
    ):
        raise ValueError(f"Unsuccessful XCTest summary: {summary}")
    print("XCTest passed all 19 Dart integration tests and 5 native cancellation tests.")


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as summary_file:
        summary = json.load(summary_file)
    with open(sys.argv[2], encoding="utf-8") as report_file:
        report = json.load(report_file)
    verify(summary, report)
