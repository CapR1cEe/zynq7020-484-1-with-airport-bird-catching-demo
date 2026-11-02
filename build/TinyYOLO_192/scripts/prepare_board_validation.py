"""Prepare a fresh Linux board validation directory for the supplied final bitstream."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reference = root/'verification/golden_reference'
    artifact_manifest = root/'reports/artifact_sha256.json'
    artifacts = json.loads(artifact_manifest.read_text(encoding='utf-8-sig'))
    destination = Path(os.path.abspath(str(args.output)))
    copies = ('expected.json', 'linux_board_validate.py', 'board_input_contract.py',
              'input_contract.json')
    links = {'tinyyolo_linux': root/'linux/tinyyolo_linux',
             'parameters.bin': root/'model/parameters.bin',
             'bird.bin': reference/'bird.bin', 'random.bin': reference/'random.bin'}
    for source in [reference/name for name in copies] + list(links.values()):
        if not source.is_file():
            raise RuntimeError('Missing validation input: '+str(source))
    if not os.access(str(links['tinyyolo_linux']), os.X_OK):
        raise RuntimeError('Run make -C linux userspace on the ARM board first')
    destination.mkdir(parents=True)
    for name in copies:
        shutil.copy2(str(reference/name), str(destination/name))
    # Preserve golden tensor hashes; label the new run with the delivered artifacts.
    # This is a target identity, never a claim that JTAG programming has succeeded.
    expected_path = destination/'expected.json'
    expected = json.loads(expected_path.read_text())
    expected['hardware']['bit_sha256'] = artifacts['firmware/final_192.bit']['sha256']
    expected['hardware']['xsa_sha256'] = artifacts['firmware/final_192.xsa']['sha256']
    expected_path.write_text(json.dumps(expected, indent=2)+'\n')
    for name, source in links.items():
        os.symlink(str(source.resolve()), str(destination/name))
    receipt = {'status': 'PREPARED_ONLY', 'board_tested': False,
               'artifact_manifest_sha256': hashlib.sha256(artifact_manifest.read_bytes()).hexdigest(),
               'golden_reference_sha256': hashlib.sha256((reference/'expected.json').read_bytes()).hexdigest(),
               'files_sha256': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                                for name, path in links.items()},
               'expected_hardware': json.loads((destination/'expected.json').read_text())['hardware']}
    (destination/'prepared.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('PREPARED_BOARD_VALIDATION '+str(destination))
    print('Program firmware/final_192.bit before running linux_board_validate.py.')


if __name__ == '__main__':
    main()
