# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "opentelemetry-sdk>=1.36",
#   "opentelemetry-exporter-otlp-proto-http>=1.36",
# ]
# ///
"""Export the harness's completed JSONL spans to an OTLP/HTTP collector."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from collections import defaultdict

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode


def collector_url(value: str) -> str:
    value = value.rstrip("/")
    return value if value.endswith("/v1/traces") else f"{value}/v1/traces"


def export_trace(tracer: trace.Tracer, records: list[dict]) -> None:
    spans: dict[str, trace.Span] = {}
    ordered = sorted(records, key=lambda item: item["start_time_unix_nano"])

    for record in ordered:
        parent_id = record.get("parent_span_id")
        parent = spans.get(parent_id)
        context = trace.set_span_in_context(parent) if parent is not None else None
        span = tracer.start_span(
            record["name"],
            context=context,
            start_time=record["start_time_unix_nano"],
        )
        spans[record["span_id"]] = span
        for key, value in record.get("attributes", {}).items():
            if value is not None:
                span.set_attribute(key, value)
        span.set_attribute("lisp.trace_id", record["trace_id"])
        span.set_attribute("lisp.span_id", record["span_id"])
        status = record.get("status", "OK")
        span.set_status(
            Status(StatusCode.ERROR if status == "ERROR" else StatusCode.OK)
        )

    for record in sorted(records, key=lambda item: item["end_time_unix_nano"]):
        spans[record["span_id"]].end(end_time=record["end_time_unix_nano"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--project", default="shift")
    args = parser.parse_args()

    provider = TracerProvider(
        resource=Resource.create(
            {
                "service.name": "shift",
                "openinference.project.name": args.project,
            }
        )
    )
    # The exporter is optional observability, never part of the agent's critical
    # path. Keep collector failures quiet and bound shutdown latency.
    logging.getLogger("opentelemetry.exporter.otlp.proto.http.trace_exporter").setLevel(
        logging.CRITICAL
    )
    exporter = OTLPSpanExporter(endpoint=collector_url(args.endpoint), timeout=1)
    provider.add_span_processor(
        BatchSpanProcessor(
            exporter,
            max_queue_size=256,
            schedule_delay_millis=200,
            max_export_batch_size=64,
            export_timeout_millis=1000,
        )
    )
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("shift")
    pending: dict[str, list[dict]] = defaultdict(list)

    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            record = json.loads(line)
            trace_id = record["trace_id"]
            pending[trace_id].append(record)
            if record.get("parent_span_id") is None:
                export_trace(tracer, pending.pop(trace_id))
    finally:
        for records in pending.values():
            export_trace(tracer, records)
        provider.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
