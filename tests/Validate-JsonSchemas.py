"""Validate every M01 governed JSON document with Draft 2020-12 schemas."""

from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parent.parent
PAIRS = (
    ("manifest/product-manifest.json", "schemas/product-manifest.schema.json"),
    ("manifest/trusted-sources.json", "schemas/trusted-sources.schema.json"),
    ("governance/product-scope.json", "schemas/product-scope.schema.json"),
    ("governance/support-matrix.json", "schemas/support-matrix.schema.json"),
    ("governance/extension-service-policy.json", "schemas/extension-service-policy.schema.json"),
    ("acceptance/vm-zh/evidence.json", "acceptance/evidence-schema.json"),
    ("acceptance/vm-en/evidence.json", "acceptance/evidence-schema.json"),
    ("acceptance/release-decision.json", "acceptance/release-decision.schema.json"),
)

SCHEMA_ONLY = (
    "schemas/diagnostic-report.schema.json",
    "schemas/extension-install-record.schema.json",
)


def load(relative: str) -> object:
    with (ROOT / relative).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def main() -> None:
    validated: list[str] = []
    for document_path, schema_path in PAIRS:
        schema = load(schema_path)
        Draft202012Validator.check_schema(schema)
        Draft202012Validator(schema, format_checker=FormatChecker()).validate(load(document_path))
        validated.append(document_path)
    for schema_path in SCHEMA_ONLY:
        Draft202012Validator.check_schema(load(schema_path))
        validated.append(schema_path + " (schema)")
    print(json.dumps({"status": "PASS", "validated": validated}, ensure_ascii=False))


if __name__ == "__main__":
    main()
