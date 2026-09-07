"""The equivalence boundary must never hide an actual automation edit."""
import importlib.util
from pathlib import Path
import unittest

import yaml

spec = importlib.util.spec_from_file_location(
    'automation_equivalent', Path(__file__).resolve().parents[1] / 'data/automation-equivalent.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
canonical = module.canonical


class AutomationEquivalenceTests(unittest.TestCase):
    def test_editor_serialization_and_supported_aliases(self):
        before = '''
- id: oven
  trigger:
    - platform: state
      entity_id: sensor.oven
  action:
    - choose:
        - conditions: '{{ true }}'
          sequence:
            - service: notify.mobile_app
              data:
                message: >-
                  Oven timer
                  is ready
'''
        after = yaml.safe_dump(yaml.safe_load(before), sort_keys=True)
        after = after.replace('trigger:', 'triggers:').replace('platform:', 'trigger:')
        after = after.replace('action:', 'actions:').replace('service:', 'action:')
        self.assertEqual(canonical(before), canonical(after))

    def test_scalar_types_strings_and_order_are_preserved(self):
        for left, right in [('true', '1'), ('1', '1.0'), ('1', "'1'"),
                            ('"a b"', '"a  b"'), ('"a\\n"', '"a"'),
                            ('[first, second]', '[second, first]')]:
            with self.subTest(left=left, right=right):
                self.assertNotEqual(canonical('- id: test\n  value: ' + left),
                                    canonical('- id: test\n  value: ' + right))

    def test_aliases_do_not_rename_user_data_or_variables(self):
        for field in ['data', 'variables', 'target']:
            before = '- id: test\n  actions:\n  - action: script.test\n    ' + field + ':\n      service: x\n'
            after = before.replace('      service:', '      action:')
            self.assertNotEqual(canonical(before), canonical(after))

    def test_actual_nested_action_change_is_not_equivalent(self):
        before = '- id: test\n  action:\n  - repeat:\n      count: 2\n      sequence:\n      - service: light.turn_on\n'
        self.assertNotEqual(canonical(before), canonical(before.replace('turn_on', 'turn_off')))
        self.assertEqual(canonical(before), canonical(before.replace('service:', 'action:')))

    def test_variable_and_user_data_order_are_preserved(self):
        for field in ['variables', 'trigger_variables', 'data']:
            before = '- id: test\n  ' + field + ':\n    first: 1\n    second: "{{ first }}"\n'
            after = '- id: test\n  ' + field + ':\n    second: "{{ first }}"\n    first: 1\n'
            self.assertNotEqual(canonical(before), canonical(after))

    def test_ambiguous_or_unsupported_yaml_is_rejected(self):
        cases = ['- id: a\n  id: b', '- id: a\n  trigger: []\n  triggers: []',
                 '- id: a\n  action:\n  - service: x\n    action: y',
                 '- id: a\n  value: !secret test', '- &a {id: a}\n- *a',
                 'not: an automation list', '- id: a\n  value: {true: 1}',
                 '- id: a\n  value: {<<: {a: b}}', '- scalar', '- id: [']
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises((ValueError, yaml.YAMLError)):
                    canonical(value)


if __name__ == '__main__':
    unittest.main()
