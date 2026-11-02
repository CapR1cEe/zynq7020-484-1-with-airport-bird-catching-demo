"""Check observable planning bounds and invalid-input handling."""
import copy
import json
from pathlib import Path
import unittest
from resource_plan import plan


class PlanningBounds(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[1]/'assets/design-contract.example.json'
        self.contract = json.loads(source.read_text(encoding='utf-8'))

    def test_parallel_and_shared_operator_throughput(self):
        candidates = plan(self.contract)['candidates']
        self.assertEqual([c['necessary_ii_lower_bound_cycles'] for c in candidates], [1, 2])
        self.assertTrue(candidates[0]['required_ii_not_ruled_out_by_bounds'])
        self.assertFalse(candidates[1]['required_ii_not_ruled_out_by_bounds'])
        self.assertEqual(candidates[0]['implementation_feasibility'], 'unproven')

    def test_operator_latency_is_not_an_input_initiation_interval(self):
        group = self.contract['candidates'][0]['operators'][0]
        group['operator_ii_cycles'] = 3
        self.assertEqual(plan(self.contract)['candidates'][0]['necessary_ii_lower_bound_cycles'], 3)

    def test_recurrence_requires_interleaving_or_larger_ii(self):
        self.contract['candidates'][0]['recurrences'] = [
            {'name': 'feedback', 'feedback_latency_cycles': 5, 'dependence_distance': 2}]
        self.assertEqual(plan(self.contract)['candidates'][0]['necessary_ii_lower_bound_cycles'], 3)

    def test_external_bandwidth_in_seconds_scales_with_clock(self):
        self.contract['candidates'][0]['transfers'] = [
            {'name': 'DDR', 'bytes_per_token': 64, 'effective_bytes_per_second': 1_600_000_000}]
        self.assertEqual(plan(self.contract)['candidates'][0]['necessary_ii_lower_bound_cycles'], 8)
        self.contract['target_frequency_mhz'] = 100
        self.assertEqual(plan(self.contract)['candidates'][0]['necessary_ii_lower_bound_cycles'], 4)

    def test_resource_violation_is_separate_from_ii_bound(self):
        self.contract['resource_caps']['DSP'] = 2
        candidate = plan(self.contract)['candidates'][0]
        self.assertTrue(candidate['required_ii_not_ruled_out_by_bounds'])
        self.assertEqual(candidate['estimated_cap_violations']['DSP'], {'estimated': 4, 'cap': 2})

    def test_rejects_invalid_numbers_and_ambiguous_bandwidth(self):
        for value in [0, -1, True, float('nan'), float('inf')]:
            c = copy.deepcopy(self.contract)
            c['target_frequency_mhz'] = value
            with self.subTest(frequency=value), self.assertRaises(ValueError):
                plan(c)
        c = copy.deepcopy(self.contract)
        c['candidates'][0]['transfers'][0]['effective_bytes_per_second'] = 1
        with self.assertRaises(ValueError):
            plan(c)
        c = copy.deepcopy(self.contract)
        c['candidates'][0]['operators'][0]['instances'] = True
        with self.assertRaises(ValueError):
            plan(c)


if __name__ == '__main__':
    unittest.main()
