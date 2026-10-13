#!/usr/bin/env python3
"""Aggregate safe profiling measurements; vendor attribution stays separate from estimates."""
import argparse
from collections import Counter
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--benchmark', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    benchmark = json.loads(Path(args.benchmark).read_text())
    task_by_run = {row['run_id']: row['task'] for row in benchmark['results'] if row.get('agent', 'lemon') == 'lemon' and row.get('run_id')}
    requests = {}
    for line in Path(args.input).read_text().splitlines():
        row = json.loads(line)
        if row['run_id'] not in task_by_run: continue
        key = (row['run_id'], row['session_id'], row['request_index'])
        requests.setdefault(key, {}).update(row)
    estimates, repeated, fields = Counter(), Counter(), {}
    tool_schemas, outputs, sections = {}, {}, {}
    totals = Counter()
    per_task = {}
    for row in requests.values():
        task = task_by_run[row['run_id']]
        item = per_task.setdefault(task, {'requests': 0, 'input_tokens': 0, 'cached_input_tokens': 0, 'output_tokens': 0, 'estimates': Counter()})
        item['requests'] += 1
        estimates.update(row.get('estimates', {}))
        repeated.update(row.get('repeated_estimates', {}))
        item['estimates'].update(row.get('estimates', {}))
        usage = row.get('provider_usage') or {}
        if usage: totals['completed_usage_requests'] += 1
        for source, target in [('input_tokens', 'input_tokens'), ('cache_read_tokens', 'cached_input_tokens'), ('output_tokens', 'output_tokens')]:
            value = usage.get(source)
            if isinstance(value, (int, float)):
                totals[target] += value
                item[target] += value
        totals['opaque_replay_bytes'] += row.get('opaque_replay_bytes', 0)
        for name, values in usage.get('request_fields', {}).items():
            fields.setdefault(name, Counter()).update(values)
            totals['field_attribution_requests'] += name == 'instructions'
        for name, values in row.get('instruction_sections', {}).items():
            sections.setdefault(name, Counter()).update(values)
        for schema in row.get('tool_schemas', []):
            name = schema['name']
            stat = tool_schemas.setdefault(name, {'name': name, 'requests': 0, 'tokens_estimate_sum': 0, 'max_tokens_estimate': 0, 'max_bytes': 0, 'calls': 0})
            stat['requests'] += 1
            stat['tokens_estimate_sum'] += schema['tokens_estimate']
            stat['max_tokens_estimate'] = max(stat['max_tokens_estimate'], schema['tokens_estimate'])
            stat['max_bytes'] = max(stat['max_bytes'], schema['bytes'])
        for entry in row.get('input_items', []):
            if entry['category'] == 'tool_arguments' and not entry['repeated']:
                name = entry.get('tool', 'unknown')
                if name in tool_schemas: tool_schemas[name]['calls'] += 1
            if entry['category'] == 'tool_output':
                stat = outputs.setdefault(entry['hash'], {'tool': entry.get('tool', 'unknown'), 'tokens_estimate': entry['tokens_estimate'], 'bytes': entry['bytes'], 'appearances': 0})
                stat['appearances'] += 1
    report = {'schema_version': 1, 'suite': 'lemon_request_profile', 'requests': len(requests),
              'vendor_usage': dict(totals), 'vendor_request_fields': {key: dict(value) for key, value in fields.items()},
              'visible_wire_estimates': dict(estimates), 'repeated_visible_wire_estimates': dict(repeated),
              'instruction_sections_estimates': {key: dict(value) for key, value in sections.items()},
              'tool_schemas': sorted(tool_schemas.values(), key=lambda row: row['max_tokens_estimate'], reverse=True),
              'largest_tool_outputs': sorted(outputs.values(), key=lambda row: row['tokens_estimate'] * row['appearances'], reverse=True)[:20],
              'tasks': per_task,
              'measurement_note': 'Vendor input/cache/output and request_fields are reported counts. o200k_base visible JSON/text estimates are not provider billing totals; encrypted replay is excluded. Repetition is a subset, not an additive category.'}
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'requests': len(requests), 'vendor_usage': dict(totals), 'vendor_request_fields': report['vendor_request_fields'], 'estimates': dict(estimates), 'repeated': dict(repeated)}, indent=2))
    if not requests or totals['completed_usage_requests'] != len(requests):
        raise SystemExit('Profile incomplete: missing request/terminal usage measurements')


if __name__ == '__main__':
    main()
