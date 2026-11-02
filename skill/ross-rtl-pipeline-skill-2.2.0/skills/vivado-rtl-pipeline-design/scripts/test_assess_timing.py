"""Check that partial or setup-only evidence cannot masquerade as timing success."""
import unittest
from assess_timing import assess, REQUIRED_CHECKS


def report(wns='0.041',whs='0.015',state='Routed'):
    checks='\n'.join(f'{i}. checking {name} (0)' for i,name in enumerate(REQUIRED_CHECKS,1))
    return f'''| Design State : {state}
WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints
------- ------- --------------------- ------------------- ------- ------- --------------------- ------------------- -------- -------- ---------------------- --------------------
{wns} 0.000 0 311 {whs} 0.000 0 311 2.000 0.000 0 143
{checks}
'''


class EvidenceBoundaries(unittest.TestCase):
    def test_summary_pass_retains_other_review(self):
        result=assess(report(),'integrated')
        self.assertEqual(result['status'],'summary_pass_review_remaining')
        self.assertFalse(result['signoff'])
        self.assertTrue(result['remaining_review'])

    def test_positive_setup_cannot_hide_negative_hold(self):
        result=assess(report(whs='-0.480'),'ooc')
        self.assertEqual(result['status'],'timing_fail')
        self.assertEqual(result['metrics']['whs_ns'],-0.480)

    def test_missing_or_na_minmax_is_incomplete(self):
        for source in ['',report(whs='N/A'),report().replace('WHS(ns)','hold unavailable')]:
            with self.subTest(source=source[:30]):
                self.assertEqual(assess(source,'integrated')['status'],'incomplete')

    def test_synthesis_or_unknown_context_not_routed_success(self):
        self.assertEqual(assess(report(state='Synthesized'),'integrated')['status'],'incomplete')
        for context in ['unknown','ooc']:
            self.assertEqual(assess(report(),context)['status'],'incomplete')

    def test_missing_or_unconstrained_endpoints_are_not_ignored(self):
        source=report().replace('checking no_input_delay (0)','input check omitted')
        self.assertEqual(assess(source,'integrated')['status'],'incomplete')
        source=report().replace('unconstrained_internal_endpoints (0)','unconstrained_internal_endpoints (1)')
        self.assertEqual(assess(source,'integrated')['status'],'timing_fail')

    def test_failing_count_survives_rounded_zero_slack(self):
        source=report().replace('0.015 0.000 0 311','0.000 0.000 1 311')
        self.assertEqual(assess(source,'integrated')['status'],'timing_fail')


if __name__ == '__main__':
    unittest.main()
