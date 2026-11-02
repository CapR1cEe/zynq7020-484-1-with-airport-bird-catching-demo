"""Check final artifact identity and regression receipts without running the FPGA."""
import datetime
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TIMING_WARNING_IDS = {'Timing 38-282', 'Timing 38-436', 'Route 35-39'}
RESET_TIMING_ADVISORY = (
    'Found a constraint with the -through option on pin '
    'Tiny_Yolo_i/proc_sys_reset_0/peripheral_aresetn[0] or the net immediately '
    'connecting to the pin. This constraint will block optimizations for this '
    'and all downstream leaf pins.')


def digest(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024*1024), b''):
            value.update(block)
    return value.hexdigest()


def read(name):
    return json.loads((ROOT/name).read_text(encoding='utf-8-sig'))


def read_log(name):
    data = (ROOT/name).read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8',
                       errors='replace')


def audit_reset_constraints():
    """Preserve vendor asynchronous-reset timing exceptions, with their origin."""
    scopes = []
    with zipfile.ZipFile(ROOT/'firmware/final_192_routed.dcp') as archive:
        for name in archive.namelist():
            if not name.endswith('.xdc'):
                continue
            scope = ''
            for line in archive.read(name).decode().splitlines():
                if line.startswith('current_instance '):
                    scope = line[len('current_instance '):]
                if line.startswith('set_false_path -through '):
                    require('xpm_cdc_async_rst' in scope and 'src_arst' in line,
                            'Unexpected through timing exception: '+line)
                    scopes.append(dict(checkpoint_member=name, scope=scope, constraint=line))
    require(bool(scopes), 'Expected vendor XPM reset timing constraints missing')
    result = dict(status='AUDITED_VENDOR_RESET_TIMING_EXCEPTION',
                  warning_id='Physopt 32-894', message=RESET_TIMING_ADVISORY,
                  classification='timing_optimization_limitation',
                  vendor_exceptions=scopes, exceptions_removed=False,
                  severity_changed=False,
                  note='XPM asynchronous-reset false paths can prevent reset-net replication. '
                       'They are retained to preserve vendor CDC timing constraints.')
    (ROOT/'reports/reset_constraint_audit.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def audit_synchronous_reset_distribution():
    receipt = read('reports/synchronous_reset_distribution.json')
    require(receipt['status'] == 'PASS_SAME_EDGE_RESET_DISTRIBUTION' and
            receipt['added_reset_cycles'] == 0 and receipt['maximum_replica_fanout'] == 64 and
            receipt['clock_enable_data_set_and_init_checked'] is True and
            receipt['path_exceptions_changed'] is False,
            'Same-edge reset distribution proof missing')
    with (ROOT/'reports/synchronous_reset_distribution.tsv').open() as stream:
        rows = list(csv.DictReader(stream, delimiter='\t'))
    replicas = [row for row in rows if row['operation'] == 'IDENTICAL_FDSE']
    bypasses = [row for row in rows if row['operation'] == 'BYPASS_INVERTER']
    buffers = [row for row in rows if row['operation'] == 'BYPASS_BUFFER']
    retained = [row for row in rows if row['operation'] == 'RETAIN_DIRECT_INPUT']
    kept = [row for row in rows if row['operation'] == 'KEEP_POSITIVE_INPUT']
    complements = [row for row in rows if row['operation'] == 'COMPLEMENT_INPUT']
    require(len(replicas) == receipt['replicas'] and
            len(bypasses) == receipt['bypassed_inverters'] and
            len(buffers) == receipt.get('flattened_buffers', 0) and
            len(retained) == receipt.get('preserved_low_inputs', 0) and
            len(complements) == receipt['complemented_lut_inputs'] and
            len(rows) == (len(replicas) + len(bypasses) + len(buffers) +
                          len(retained) + len(kept) + len(complements)),
            'Reset transformation operation counts differ')
    require(sum(int(row['loads']) for row in replicas) == receipt['loads'] and
            all(1 <= int(row['loads']) <= 64 and 'INIT=1\'b1;' in row['detail']
                for row in replicas) and
            all(row['detail'] == "2'h1" for row in bypasses),
            'Unexpected reset replica fanout, INIT, or inverter')
    require(all(row['detail'] == "2'h2" for row in buffers) and
            all(int(row['loads']) >= 0 for row in buffers + retained + kept),
            'Unexpected reset buffer flattening or retained endpoint')
    for row in complements:
        pin, old, new = row['detail'].rsplit(':', 2)
        index = int(re.fullmatch(r'.*/I([0-5])', pin)[1])
        old_match = re.fullmatch(r"(\d+)'h([0-9a-fA-F]+)", old)
        new_match = re.fullmatch(r"(\d+)'h([0-9a-fA-F]+)", new)
        require(old_match and new_match and old_match[1] == new_match[1], 'Invalid LUT truth table')
        old_bits, new_bits = int(old_match[2], 16), int(new_match[2], 16)
        require(all((new_bits >> address) & 1 == (old_bits >> (address ^ (1 << index))) & 1
                    for address in range(int(old_match[1]))),
                'Reset LUT truth-table complement differs: ' + row['cell'])
    folder = 'verification/synchronous_reset_equivalence/'
    primitive = read(folder+'result.json')
    require(primitive['status'] == 'PASS_SAME_EDGE_RESET_PRIMITIVE_EQUIVALENCE' and
            primitive['backend'] == 'AMD_UNISIM' and primitive['cycles'] == 4096 and
            primitive['added_reset_cycles'] == 0,
            'Reset primitive equivalence regression missing')
    check_hashes(primitive['sha256'], folder)
    require(read_log(folder+'simulation.log').splitlines().count(primitive['marker']) == 1,
            'Reset equivalence completion marker missing')
    return receipt


def audit_firmware_payload():
    """Compare actual FPGA configuration bytes, allowing only header timestamps."""
    def parse(data):
        offset = 0

        def take(size):
            nonlocal offset
            require(size >= 0 and offset + size <= len(data), 'Truncated .bit file')
            value = data[offset:offset+size]
            offset += size
            return value

        def integer(size):
            return struct.unpack('>H' if size == 2 else '>I', take(size))[0]

        require(take(integer(2)) == bytes.fromhex('0ff00ff00ff00ff000'), 'Invalid .bit magic')
        require(integer(2) == 1, 'Invalid .bit header tag length')
        headers = {}
        for tag in ('a', 'b', 'c', 'd', 'e'):
            require(take(1) == tag.encode('ascii'), 'Unexpected .bit header tag: '+tag)
            value = take(integer(4 if tag == 'e' else 2))
            if tag == 'e':
                payload = value
            else:
                require(value.endswith(b'\0'), 'Unterminated .bit header: '+tag)
                headers[tag] = value[:-1].decode('ascii')
        require(offset == len(data) and len(payload) > 0, 'Invalid .bit payload length')
        return headers, payload

    supplied = (ROOT/'firmware/final_192.bit').read_bytes()
    with zipfile.ZipFile(ROOT/'firmware/final_192.xsa') as archive:
        members = [name for name in archive.namelist() if name.endswith('.bit')]
        require(len(members) == 1, 'XSA must contain exactly one bitstream')
        embedded = archive.read(members[0])
    supplied_headers, supplied_payload = parse(supplied)
    embedded_headers, embedded_payload = parse(embedded)
    require(supplied_payload == embedded_payload, 'XSA configuration payload differs from supplied bitstream')
    require(all(supplied_headers[tag] == embedded_headers[tag] for tag in ('a', 'b')),
            'XSA design or FPGA part header differs from supplied bitstream')
    result = dict(status='PASS_XSA_BIT_CONFIGURATION_IDENTITY', xsa_member=members[0],
                  configuration_bytes=len(supplied_payload),
                  configuration_sha256=hashlib.sha256(supplied_payload).hexdigest(),
                  supplied_bit_sha256=hashlib.sha256(supplied).hexdigest(),
                  embedded_bit_sha256=hashlib.sha256(embedded).hexdigest(),
                  full_files_identical=supplied == embedded,
                  supplied_headers=supplied_headers, embedded_headers=embedded_headers,
                  allowed_header_differences=['c: generation date', 'd: generation time'])
    (ROOT/'reports/firmware_payload_audit.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


def check_hashes(inventory, prefix=''):
    for name, expected in inventory.items():
        require(digest(ROOT/prefix/name) == expected, 'Source SHA mismatch: '+prefix+name)


def audit_control_guards():
    """Bind fault-edge and geometry coverage to the delivered RTL and benches."""
    folder = 'verification/control_guards/'
    guards = read(folder+'result.json')
    require(guards['status'] == 'PASS_CONTROL_GUARDS' and
            guards['backend'] == 'AMD_UNISIM' and guards['clock_mhz'] == 240,
            'Control fault/geometry regression failed')
    require(set(guards['source_sha256']) ==
            {path.name for path in (ROOT/'hardware/g227/rtl').glob('*.v')},
            'Control guard RTL inventory differs')
    check_hashes(guards['source_sha256'], 'hardware/g227/rtl/')
    check_hashes(guards['source_sha256'], folder+'rtl/')
    markers = {
        'tb_control_fault_guards': 'CONTROL_FAULT_GUARDS_PASS checks=108 '
            'immediate_zero_fault=1 bus_priority=1 restart=1',
        'tb_head_config': 'HEAD_CONFIG_PASS legal=679 invalid=24 '
            'backpressure_cycles=8 hardware_access=0',
        'tb_size_pipeline': 'SIZE_PIPELINE_PASS cases=7 full_plane=173056 '
            'signed_boundary=131072 hardware_access=0'}
    require(len(guards['suites']) == len(markers) and
            {item['top'] for item in guards['suites']} == set(markers),
            'Missing control guard regression suite')
    for item in guards['suites']:
        top = item['top']
        require(digest(ROOT/'tests'/(top+'.sv')) ==
                digest(ROOT/folder/(top+'.sv')) == item['bench_sha256'],
                'Control guard bench changed: '+top)
        require(digest(ROOT/folder/(top+'.log')) == item['log_sha256'],
                'Control guard simulation log changed: '+top)
        log = read_log(folder+top+'.log')
        require(item['marker'] == markers[top] and
                log.splitlines().count(markers[top]) == 1 and
                not re.search(r'^(?:FATAL:|Fatal:|ERROR:)', log, re.M),
                'Control guard coverage/completion differs: '+top)
    return guards


def audit_implementation_reports():
    diagnostics = []
    reports = ('reports/drc.rpt', 'reports/methodology.rpt', 'reports/cdc.rpt',
               'reports/synthesis_drc.rpt', 'reports/synthesis_methodology.rpt',
               'reports/synthesis_cdc.rpt')
    for name in reports:
        for number, line in enumerate(read_log(name).splitlines(), 1):
            match = re.match(
                r'^\|\s*(\S+)\s*\|\s*(Critical Warning|Warning|Error|Critical)\s*\|',
                line, re.I)
            if not match:
                match = re.match(r'^\s*\d+\s+(CDC-\d+)\s+(Critical|Warning|Error)\s+', line, re.I)
            if match:
                diagnostics.append(dict(file=name, line=number, id=match.group(1),
                                        severity=match.group(2), message=line.strip(),
                                        timing=match.group(1).startswith('TIMING-')))
    route = read_log('reports/route_status.rpt')
    route_errors = re.search(r'# of nets with routing errors\.+\s*:\s*(\d+)', route)
    require(route_errors is not None and int(route_errors.group(1)) == 0,
            'Routing errors remain; see route_status.rpt')
    skew_summary = read_log('reports/bus_skew.rpt').split('2. Bus Skew Report Per Constraint')[-2]
    skew = [dict(corner=m[0], requirement_ns=float(m[1]), actual_ns=float(m[2]), slack_ns=float(m[3]))
            for m in re.findall(r'(Slow|Fast)\s+([\d.]+)\s+([\d.]+)\s+(-?[\d.]+)\s*$',
                                skew_summary, re.M)]
    require(bool(skew), 'No bus skew results parsed from implemented report')
    with (ROOT/'reports/reset_cleanup.tsv').open() as stream:
        pruned = list(csv.DictReader(stream, delimiter='\t'))
    expected_pruned = {
        'Tiny_Yolo_i/smartconnect_0/inst/s00_nodes/s00_'+channel+'_node/inst/s_sc_areset_reg': 'FDSE'
        for channel in ('ar','aw','b','r','w')}
    expected_pruned.update({
        'Tiny_Yolo_i/tinyyolo_accel_0/inst/u_control/arithmetic_reset_reg['+str(index)+']': 'FDRE'
        for index in range(19,24)})
    require(len(pruned) == len(expected_pruned) and
            {item['driver']: item['primitive'] for item in pruned} == expected_pruned and
            all(item['leaf_sinks'] == '0' for item in pruned),
            'Missing reset cleanup proof')
    with (ROOT/'reports/cdc_unused_data.tsv').open() as stream:
        cdc_pruned = list(csv.DictReader(stream, delimiter='\t'))
    require(bool(cdc_pruned) and all(item['leaf_sinks'] == item['top_ports'] == '0' and
            item['primitive'] == 'FDRE' and '/inst_cdc_handshake/dest_hsdata_ff_reg' not in item['cell'] and
            '.inst_cdc_handshake/dest_hsdata_ff_reg' in item['cell'] for item in cdc_pruned),
            'Missing no-load XPM payload cleanup proof')
    result = dict(status='AUDITED_IMPLEMENTATION_REPORTS', diagnostic_reports=list(reports),
                  report_diagnostics=diagnostics, routing_errors=int(route_errors.group(1)),
                  pruned_reset_flops=pruned,
                  pruned_unused_cdc_payload_flops=cdc_pruned,
                  bus_skew_constraints=skew, bus_skew_met=all(item['slack_ns'] >= 0 for item in skew))
    (ROOT/'reports/implementation_report_audit.json').write_text(json.dumps(result, indent=2)+'\n')
    return result



if __name__ == '__main__':
    from audit_final_package import main
    main()
