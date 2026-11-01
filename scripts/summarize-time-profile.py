#!/usr/bin/env python3
"""Summarize exported xctrace time-profile weights; a developer-only tool."""
import collections
import json
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ids = {element.attrib['id']: element for element in root.iter() if 'id' in element.attrib}

def resolve(element):
    visited = set()
    while 'ref' in element.attrib:
        ref = element.attrib['ref']
        if ref in visited or ref not in ids:
            raise ValueError('Unresolved or cyclic Instruments reference')
        visited.add(ref)
        element = ids[ref]
    return element

samples = 0
weights = collections.Counter()
threads = collections.Counter()
unknown = 0
processes = set()
for node in root.findall('node'):
    schema = node.find('schema')
    if schema is None or schema.attrib.get('name') != 'time-profile':
        continue
    columns = [column.findtext('mnemonic') for column in schema.findall('col')]
    for row in node.findall('row'):
        if len(row) != len(columns):
            raise ValueError('Unexpected sample column count')
        values = {key: resolve(value) for key, value in zip(columns, row)}
        weight = int(values['weight'].text)
        if weight < 0:
            raise ValueError('Negative sample weight')
        samples += 1
        processes.add(values['process'].attrib.get('fmt', 'unknown'))
        frame = values['stack'].find('frame')
        name = resolve(frame).attrib.get('name', 'unknown') if frame is not None else 'unknown'
        if name.startswith('0x') or name == 'unknown':
            unknown += weight
        weights[name] += weight
        thread = values['thread'].attrib.get('fmt', 'unknown')
        threads['main' if thread.startswith('Main Thread') else 'other'] += weight

if samples == 0:
    raise SystemExit('No time-profile samples found; no performance summary produced.')

def milliseconds(value):
    return round(value / 1_000_000, 3)

print(json.dumps({
    'scope': 'Sampled running-thread weights for the listed trace processes. Sampling is not exact CPU-time accounting; child processes are included only when present in the captured data.',
    'processes': sorted(processes),
    'samples': samples,
    'total_sampled_weight_ms': milliseconds(sum(weights.values())),
    'main_thread_weight_ms': milliseconds(threads['main']),
    'other_threads_weight_ms': milliseconds(threads['other']),
    'unsymbolicated_leaf_weight_ms': milliseconds(unknown),
    'top_leaf_frames': [{'name': name, 'sampled_weight_ms': milliseconds(value)} for name, value in weights.most_common(12)]
}, indent=2))
