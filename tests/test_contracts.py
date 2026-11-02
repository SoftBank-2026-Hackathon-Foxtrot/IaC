"""Specification conformance tests, not tests of an implemented API server."""
import importlib.util
import json
import unittest
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate

ROOT=Path(__file__).resolve().parents[1]
SPEC=yaml.safe_load((ROOT/'contracts/provisioning.openapi.yaml').read_text(encoding='utf-8'))


def validator(name):
    # Root references remain local to the OpenAPI components object.
    return Draft202012Validator({'$ref':'#/components/schemas/'+name,'components':SPEC['components']},format_checker=FormatChecker())


def fixture(name):
    return json.loads((ROOT/f'contracts/examples/{name}.json').read_text(encoding='utf-8'))


class ContractTests(unittest.TestCase):
    def test_openapi_is_structurally_valid(self):
        validate(SPEC)

    def test_all_examples_conform(self):
        index=json.loads((ROOT/'contracts/examples/index.json').read_text())
        for item in index:
            with self.subTest(file=item['file']):
                value=json.loads((ROOT/'contracts'/item['file']).read_text(encoding='utf-8'))
                validator(item['schema']).validate(value)

    def test_ui_schema_validates_defaults_and_matches_catalog(self):
        catalog=json.loads((ROOT/'catalog/sizing-policy.json').read_text(encoding='utf-8'))
        for cloud in ('aws','gcp'):
            with self.subTest(cloud=cloud):
                template=fixture(f'{cloud}-template-response')
                schema=template['input_schema']
                Draft202012Validator.check_schema(schema)
                Draft202012Validator(schema,format_checker=FormatChecker()).validate(template['default_inputs'])
                for key,rule in catalog['clouds'][cloud].items():
                    actual=schema['properties']['sizing']['properties'][key]
                    self.assertTrue(actual['x-ui']['ai_recommendable'])
                    self.assertEqual({k:actual[k] for k in rule},rule)

    def test_raw_credentials_and_arbitrary_code_rejected(self):
        for key in ('terraform_code','user_data','redis_auth_token','ami_id','image'):
            value=fixture('aws-create-request')
            value['configuration']['inputs'][key]='untrusted'
            with self.subTest(key=key):
                self.assertFalse(validator('CreateDeployment').is_valid(value))
        value=fixture('aws-create-request')
        value['configuration']['cloud_credentials']={'secret':'do-not-accept'}
        self.assertFalse(validator('CreateDeployment').is_valid(value))

    def test_cloud_specific_inputs_cannot_be_mixed(self):
        value=fixture('aws-create-request')
        value['configuration']['inputs']=fixture('gcp-create-request')['configuration']['inputs']
        self.assertFalse(validator('CreateDeployment').is_valid(value))

    def test_invalid_catalog_values_rejected(self):
        for cloud,key,value in [('aws','compute_instance_type','p5.48xlarge'),('gcp','cache_memory_gib',999),('aws','db_multi_az','false')]:
            request=fixture(f'{cloud}-create-request')
            request['configuration']['inputs']['sizing'][key]=value
            with self.subTest(cloud=cloud,key=key):
                self.assertFalse(validator('CreateDeployment').is_valid(request))

    def test_apply_requires_exact_review_identifiers(self):
        for key in ('expected_revision','plan_id','review_digest'):
            value=fixture('apply-request')
            del value[key]
            with self.subTest(key=key):
                self.assertFalse(validator('ApplyRequest').is_valid(value))
        value=fixture('apply-request')
        value['approved_by']='forged-user'
        self.assertFalse(validator('ApplyRequest').is_valid(value))

    def test_acceptance_does_not_allow_client_value_injection(self):
        value=fixture('accept-recommendation-request')
        value['values']={'compute_disk_gib':100000}
        self.assertFalse(validator('AcceptRecommendation').is_valid(value))

    def test_handoff_cannot_claim_application_readiness(self):
        for cloud in ('aws','gcp'):
            value=fixture(f'{cloud}-handoff-response')
            value['readiness']='APPLICATION_READY'
            self.assertFalse(validator('Handoff').is_valid(value))

    def test_mutations_have_idempotency_and_permissions(self):
        for path,item in SPEC['paths'].items():
            for method,operation in item.items():
                with self.subTest(path=path,method=method):
                    self.assertIn('x-required-permission',operation)
                    if method in ('post','put'):
                        self.assertIn({'$ref':'#/components/parameters/IdempotencyKey'},operation['parameters'])

    def test_generated_files_are_current(self):
        spec=importlib.util.spec_from_file_location('build_contract',ROOT/'tools/build_contract.py')
        module=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for path,content in module.make_artifacts().items():
            with self.subTest(path=path):
                self.assertEqual((ROOT/path).read_text(encoding='utf-8'),content)


if __name__=='__main__':
    unittest.main()
