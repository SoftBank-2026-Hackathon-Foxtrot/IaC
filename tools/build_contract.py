"""Build the reviewable OpenAPI draft and examples from the existing sizing catalog.

This generates specification artifacts only. It does not implement HTTP endpoints.
Run: python tools/build_contract.py [--check]
"""
import argparse
import copy
import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ReadableDumper(yaml.SafeDumper):
    def ignore_aliases(self, data):
        return True


def obj(properties, required=None):
    return {"type": "object", "additionalProperties": False, "properties": properties,
            "required": list(properties) if required is None else required}


def string(**kwargs):
    return {"type": "string", **kwargs}


def array(items, **kwargs):
    return {"type": "array", "items": items, **kwargs}


def ref(name):
    return {"$ref": "#/components/schemas/" + name}


def make_artifacts():
    policy = json.loads((ROOT / "catalog/sizing-policy.json").read_text(encoding="utf-8"))
    defaults = {c: json.loads((ROOT / f"environments/{c}/deployment.example.tfvars.json").read_text(encoding="utf-8")) for c in ("aws", "gcp")}
    schemas = {}
    identifier = string(pattern="^[a-zA-Z0-9_-]{3,100}$")
    revision = {"type": "integer", "minimum": 1}
    digest = string(pattern="^sha256:[0-9a-f]{64}$")
    date_time = string(format="date-time")
    cloud_schema = string(enum=["aws", "gcp"])
    cidr = string(description="IPv4 CIDR; host bits, overlap and subnet containment require semantic validation.")

    def infer(value):
        if isinstance(value, dict):
            return obj({k: infer(v) for k, v in value.items()})
        if isinstance(value, list):
            return array(infer(value[0]) if value else string())
        if type(value) is bool:
            return {"type": "boolean"}
        if type(value) is int:
            return {"type": "integer"}
        return string()

    label_titles = {
        "compute_instance_type": "앱 서버 사양", "compute_machine_type": "앱 서버 사양",
        "compute_disk_gib": "앱 디스크 용량 (GiB)", "db_instance_class": "DB 사양", "db_tier": "DB 사양",
        "db_storage_gib": "DB 초기 용량 (GiB)", "db_max_storage_gib": "DB 자동 확장 상한 (GiB)",
        "db_multi_az": "DB Multi-AZ", "db_high_availability": "DB 고가용성",
        "cache_node_type": "캐시 노드 사양", "cache_node_count": "캐시 노드 수",
        "cache_memory_gib": "캐시 메모리 (GiB)", "cache_high_availability": "캐시 고가용성"
    }
    inputs_by_cloud = {}
    for cloud in ("aws", "gcp"):
        sizing = copy.deepcopy(policy["clouds"][cloud])
        for key, schema in sizing.items():
            schema.update(title=label_titles[key], default=defaults[cloud]["sizing"][key])
            schema["x-ui"] = {"group": "sizing", "editable_by": ["editor"], "ai_recommendable": True}
        schemas[f"{cloud.title()}Sizing"] = obj(sizing)
        props = {k: infer(v) for k, v in defaults[cloud].items() if k != "sizing"}
        for key, schema in props.items():
            schema["x-ui"] = {"group": "platform", "editable_by": ["editor"], "ai_recommendable": False}
            schema["title"] = {
                "deployment_id": "클라우드 자원 이름 접두사", "metadata": "소유권·비용 추적 정보",
                "region": "리전", "zone": "가용 영역", "account_id": "AWS 계정",
                "project_id": "GCP 프로젝트", "bucket_name": "파일 저장소 이름",
                "database_name": "초기 DB 이름", "network": "네트워크 구성",
                "deletion_protection": "DB 삭제 보호", "final_snapshot_identifier": "삭제 전 최종 스냅샷 이름"
            }.get(key, key)
        props["deployment_id"].update(pattern="^[a-z][a-z0-9-]{2,19}$", description="Cloud-native deployment name. Immutable after draft creation.")
        props["metadata"]["properties"] = {k: string(pattern="^[a-z0-9][a-z0-9_-]{0,62}$") for k in defaults[cloud]["metadata"]}
        props["metadata"]["properties"]["environment"] = string(enum=["poc", "dev"])
        props["metadata"]["properties"]["data_class"] = string(enum=["public", "internal", "confidential"])
        props["metadata"]["properties"]["expires_on"] = string(format="date")
        props["web_ports"] = array({"type": "integer", "enum": [80,443,8080]}, minItems=1, uniqueItems=True)
        props["web_ingress_cidrs"] = array(cidr, minItems=1, uniqueItems=True)
        props["admin_cidrs"] = array(cidr, uniqueItems=True, description="/24~32 only. Empty by default.")
        for key in ("web_ports", "web_ingress_cidrs", "admin_cidrs", "deletion_protection", "network"):
            props[key]["x-ui"] = {"group": "network-policy", "editable_by": ["infra_admin"], "ai_recommendable": False}
        props["bucket_name"].update(pattern="^[a-z][a-z0-9-]{1,61}[a-z0-9]$")
        props["database_name"].update(pattern="^[a-z][a-z0-9]{0,30}$")
        props["sizing"] = ref(f"{cloud.title()}Sizing")
        if cloud == "aws":
            props["account_id"].update(pattern="^[0-9]{12}$")
            props["network"]["properties"]["private_subnet_cidrs"] = array(cidr, minItems=2, maxItems=2, uniqueItems=True)
            props["network"]["properties"]["availability_zones"] = array(string(), minItems=2, maxItems=2, uniqueItems=True)
            props["key_name"] = {"type": ["string", "null"], "description": "Existing key pair; infra_admin only.", "x-ui":{"group":"network-policy","editable_by":["infra_admin"],"ai_recommendable":False}}
        else:
            props["network"]["properties"]["service_range_prefix"] = {"type":"integer","minimum":16,"maximum":20}
        inputs = obj(props, [k for k in props if k != "key_name"])
        schemas[f"{cloud.title()}Inputs"] = inputs
        inputs_by_cloud[cloud] = inputs
        secrets = obj({"redis_auth": identifier}) if cloud == "aws" else obj({})
        schemas[f"{cloud.title()}Configuration"] = obj({
            "template_id": {"const": f"{cloud}-web"}, "template_version": {"const":"v0.1"},
            "cloud_connection_id": identifier, "image_profile_id": identifier,
            "secret_bindings": secrets, "inputs": ref(f"{cloud.title()}Inputs")
        })
    schemas["Configuration"] = {"oneOf":[ref("AwsConfiguration"),ref("GcpConfiguration")]}
    schemas["CreateDeployment"] = obj({"configuration":ref("Configuration")})
    schemas["ReplaceConfiguration"] = obj({"expected_revision":revision,"configuration":ref("Configuration")})
    states = ["DRAFT","PLANNING","PLAN_READY","APPLYING","PROVISIONED","FAILED","NEEDS_RECONCILIATION"]
    actions = ["EDIT_CONFIGURATION","REQUEST_RECOMMENDATION","CREATE_PLAN","APPROVE_APPLY","READ_HANDOFF"]
    schemas["Deployment"] = obj({
        "id":identifier,"revision":revision,"configuration":ref("Configuration"),
        "state":string(enum=states),"active_job_id":{"type":["string","null"]},
        "latest_plan_id":{"type":["string","null"]},"allowed_actions":array(string(enum=actions),uniqueItems=True)
    })
    schemas["TemplateSummary"] = obj({"id":string(enum=["aws-web","gcp-web"]),"version":string(),"cloud":cloud_schema,"title":string(),"lifecycle":string(enum=["DRAFT","APPROVED","RETIRED"])})
    schemas["TemplateList"] = obj({"items":array(ref("TemplateSummary"))})
    schemas["ImageProfile"] = obj({
        "id":identifier,"revision":revision,"os":string(),"architecture":string(enum=["x86_64"]),
        "status":string(enum=["APPROVED","UNAVAILABLE"]),"container_runtime":string(enum=["INSTALLED","NOT_INSTALLED","UNVERIFIED"])
    })
    schemas["Template"] = obj({
        "id":string(enum=["aws-web","gcp-web"]),"version":string(),"cloud":cloud_schema,
        "lifecycle":string(enum=["DRAFT","APPROVED","RETIRED"]),
        "input_schema":{"type":"object","additionalProperties":True,"description":"Standalone JSON Schema 2020-12 for inputs, with x-ui annotations. No unresolved refs."},
        "default_inputs":{"oneOf":[ref("AwsInputs"),ref("GcpInputs")]},
        "image_profiles":array(ref("ImageProfile")),"fixed_rules":array(string()),"limitations":array(string())
    })
    schemas["RevisionRequest"] = obj({"expected_revision":revision})
    schemas["RecommendationRequest"] = obj({"expected_revision":revision,"requirements":string(minLength=1,maxLength=4000)})
    schemas["SuggestedChange"] = obj({
        "field":string(pattern="^sizing\\.[a-z_]+$"),"current_value":{"type":["string","integer","boolean"]},
        "proposed_value":{"type":["string","integer","boolean"]},"reason":string(minLength=1,maxLength=2000)
    })
    schemas["Recommendation"] = obj({
        "id":identifier,"deployment_id":identifier,"based_on_revision":revision,
        "status":string(enum=["PROPOSED","NEEDS_INPUT"]),"changes":array(ref("SuggestedChange")),
        "questions":array(string()),"limitations":array(string()),"created_at":date_time
    })
    schemas["AcceptRecommendation"] = obj({"expected_revision":revision,"recommendation_id":identifier,
                                            "selected_fields":array(string(pattern="^sizing\\.[a-z_]+$"),minItems=1,uniqueItems=True)})
    schemas["Issue"] = obj({"code":string(),"field":string(),"message":string()})
    schemas["Error"] = obj({"code":string(enum=["UNAUTHENTICATED","FORBIDDEN","NOT_FOUND","INVALID_INPUT","REVISION_CONFLICT","JOB_IN_PROGRESS","PLAN_STALE","PLAN_BLOCKED","IDEMPOTENCY_CONFLICT","RECONCILIATION_REQUIRED","INVALID_STATE","RATE_LIMITED","INTERNAL_ERROR"]),
                            "message":string(),"request_id":identifier,"issues":array(ref("Issue"))})
    schemas["Job"] = obj({
        "id":identifier,"deployment_id":identifier,"type":string(enum=["RECOMMEND","PLAN","APPLY"]),
        "status":string(enum=["QUEUED","RUNNING","SUCCEEDED","FAILED","NEEDS_RECONCILIATION"]),
        "phase":string(enum=["QUEUED","VALIDATING","RECOMMENDING","INITIALIZING","PLANNING","APPLYING","COLLECTING_OUTPUTS","DONE"]),
        "message":string(),"created_at":date_time,"updated_at":date_time,
        "result":{ "oneOf":[obj({"kind":{"const":"recommendation"},"recommendation":ref("Recommendation")}),
                             obj({"kind":{"const":"plan"},"plan_id":identifier}),
                             obj({"kind":{"const":"handoff"},"deployment_id":identifier}),{"type":"null"}]},
        "error":{"oneOf":[ref("Error"),{"type":"null"}]}
    })
    schemas["ResourceChange"] = obj({"address":string(),"resource_type":string(),"action":string(enum=["CREATE","UPDATE","DELETE","REPLACE","NO_OP"]),"summary":string(description="Redacted human-readable summary; never raw provider values.")})
    schemas["Plan"] = obj({
        "id":identifier,"deployment_id":identifier,"config_revision":revision,"template_version":string(),
        "status":string(enum=["REVIEWABLE","BLOCKED","STALE","APPLIED"]),"review_digest":digest,
        "target_summary":string(),"created_at":date_time,"expires_at":date_time,
        "changes":array(ref("ResourceChange")),"warnings":array(string()),"blockers":array(ref("Issue")),
        "cost_estimate":obj({"status":{"const":"NOT_AVAILABLE"},"message":string()}),
        "approved_by":{"type":["string","null"]},"approved_at":{"type":["string","null"],"format":"date-time"}
    })
    schemas["ApplyRequest"] = obj({"expected_revision":revision,"plan_id":identifier,"review_digest":digest})

    # These match the current Terraform `handoff` object; adapter adds an envelope.
    metadata = {"type":"object","additionalProperties":string()}
    compute = obj({"id":string(),"public_ip":string(),"private_ip":string(),"identity":string()})
    for cloud in ("aws","gcp"):
        db = {"id":string(),"host":string(),"port":{"const":5432},"name":string(),"tls_required":{"const":True}}
        cache = {"id":string(),"host":string(),"port":{"type":"integer","minimum":1,"maximum":65535},"tls_required":{"const":True},"auth_source":string()}
        if cloud == "aws":
            db["admin_secret_ref"] = string(description="Reference only; no secret material.")
            network = obj({"id":string(),"app_security_group_id":string()})
        else:
            db.update(connection_name=string(),app_db_user=string(),auth_mode={"const":"cloud-sql-iam-connector"})
            cache["server_ca_certs"] = array(obj({"cert":string(),"create_time":string(),"expire_time":string(),"serial_number":string(),"sha1_fingerprint":string()}))
            network = obj({"id":string(),"subnetwork_id":string()})
        schemas[f"{cloud.title()}Handoff"] = obj({"schema_version":{"const":1},"cloud":{"const":cloud},
            "deployment_id":string(),"metadata":metadata,"compute":compute,"database":obj(db),"cache":obj(cache),
            "storage":obj({"id":string(),"name":string()}),"network":network,"pending_checks":array(string())})
    schemas["Handoff"] = obj({"deployment_id":identifier,"applied_revision":revision,"readiness":{"const":"RESOURCES_CREATED"},
                               "container_runtime":{"const":"NOT_CHECKED"},"handoff":{"oneOf":[ref("AwsHandoff"),ref("GcpHandoff")]}})

    params = {
      "IdempotencyKey":{"name":"Idempotency-Key","in":"header","required":True,"schema":string(minLength=8,maxLength=128),"description":"Same principal+method+path+key and same body returns original result. Different body -> 409."},
      "DeploymentId":{"name":"deployment_id","in":"path","required":True,"schema":identifier},
      "JobId":{"name":"job_id","in":"path","required":True,"schema":identifier},
      "PlanId":{"name":"plan_id","in":"path","required":True,"schema":identifier},
      "TemplateId":{"name":"template_id","in":"path","required":True,"schema":string(enum=["aws-web","gcp-web"])},
      "TemplateVersion":{"name":"version","in":"path","required":True,"schema":string()}
    }
    def response(schema, desc):
        return {"description":desc,"content":{"application/json":{"schema":ref(schema)}}}
    def operation(id_, summary, perm, output, status="200", request=None, path_params=(), async_=False):
        op={"operationId":id_,"summary":summary,"x-required-permission":perm,
            "responses":{status:response(output,"Accepted; poll returned job ID." if async_ else "Success"),
                         "400":response("Error","Malformed request"),"401":response("Error","Authentication required"),
                         "403":response("Error","Permission denied"),"404":response("Error","Not found within caller scope"),
                         "409":response("Error","Revision, idempotency, active job or lifecycle conflict"),
                         "422":response("Error","Schema or semantic validation failed"),
                         "429":response("Error","Rate limited"),"500":response("Error","Unexpected failure; use request ID")}}
        op["parameters"]=[{"$ref":"#/components/parameters/"+p} for p in path_params]
        if request:
            op["parameters"].append({"$ref":"#/components/parameters/IdempotencyKey"})
            op["requestBody"]={"required":True,"content":{"application/json":{"schema":ref(request)}}}
        return op
    paths={
      "/templates":{"get":operation("listTemplates","사용 가능한 템플릿 목록","provision:read","TemplateList")},
      "/templates/{template_id}/versions/{version}":{"get":operation("getTemplate","폼 스키마·기본값·고정 규칙·이미지 후보 조회","provision:read","Template",path_params=("TemplateId","TemplateVersion"))},
      "/deployments":{"post":operation("createDeployment","설정 초안 생성 (자원 생성 없음)","provision:edit","Deployment","201","CreateDeployment")},
      "/deployments/{deployment_id}":{"get":operation("getDeployment","설정과 현재 가능한 행동 조회","provision:read","Deployment",path_params=("DeploymentId",))},
      "/deployments/{deployment_id}/configuration":{"put":operation("replaceConfiguration","전체 설정 교체와 revision 증가","provision:edit","Deployment",request="ReplaceConfiguration",path_params=("DeploymentId",))},
      "/deployments/{deployment_id}/recommendations":{"post":operation("recommendSizing","사양 추천 작업; 초안은 변경하지 않음","provision:edit","Job","202","RecommendationRequest",("DeploymentId",),True)},
      "/deployments/{deployment_id}/recommendation-acceptances":{"post":operation("acceptRecommendation","선택한 추천 항목만 서버에서 병합","provision:edit","Deployment",request="AcceptRecommendation",path_params=("DeploymentId",))},
      "/deployments/{deployment_id}/plans":{"post":operation("createPlan","특정 설정 revision의 계획 생성","provision:plan","Job","202","RevisionRequest",("DeploymentId",),True)},
      "/plans/{plan_id}":{"get":operation("getPlan","민감값을 제거한 계획과 검토 digest 조회","provision:read","Plan",path_params=("PlanId",))},
      "/deployments/{deployment_id}/apply":{"post":operation("approveAndApply","검토한 plan 승인 기록과 실행 등록을 원자적으로 처리","provision:apply","Job","202","ApplyRequest",("DeploymentId",),True)},
      "/jobs/{job_id}":{"get":operation("getJob","비동기 작업 상태 및 결과 조회","provision:read","Job",path_params=("JobId",))},
      "/deployments/{deployment_id}/handoff":{"get":operation("getHandoff","후속 모듈에 인프라 결과 인계","provision:handoff","Handoff",path_params=("DeploymentId",))}
    }
    spec={"openapi":"3.1.0","info":{"title":"Foxtrot Provisioning Interface — DRAFT","version":"0.1.0","description":"Contract proposal only. No API server, auth, job queue or runner is implemented. Base path can be mounted in the platform backend. See docs/provisioning-interface.md."},
          "servers":[{"url":"/api/v1/provisioning"}],"security":[{"platformBearer":[]}],"paths":paths,
          "components":{"securitySchemes":{"platformBearer":{"type":"http","scheme":"bearer","description":"Platform identity. Claims and every resource reference must be authorization-checked by the server."}},"parameters":params,"schemas":schemas}}

    def standalone(schema):
        if isinstance(schema,list):
            return [standalone(v) for v in schema]
        if isinstance(schema,dict):
            if "$ref" in schema:
                return standalone(schemas[schema["$ref"].split("/")[-1]])
            return {k:standalone(v) for k,v in schema.items()}
        return schema

    examples={}
    index=[]
    def example(name, schema, value):
        examples[f"contracts/examples/{name}.json"]=json.dumps(value,indent=2,ensure_ascii=False)+'\n'
        index.append({"file":f"examples/{name}.json","schema":schema})

    for cloud in ("aws","gcp"):
        config={"template_id":f"{cloud}-web","template_version":"v0.1","cloud_connection_id":f"conn_{cloud}_poc",
                "image_profile_id":"img_web_x86_v1","secret_bindings":{"redis_auth":"sec_redis_poc"} if cloud=="aws" else {},"inputs":defaults[cloud]}
        example(f"{cloud}-create-request","CreateDeployment",{"configuration":config})
        example(f"{cloud}-template-response","Template",{
            "id":f"{cloud}-web","version":"v0.1","cloud":cloud,"lifecycle":"DRAFT",
            "input_schema":{"$schema":"https://json-schema.org/draft/2020-12/schema",**standalone(inputs_by_cloud[cloud])},
            "default_inputs":defaults[cloud],"image_profiles":[],
            "fixed_rules":["database-private-only","cache-tls-and-auth","storage-public-access-blocked"],
            "limitations":["Template and image profile need explicit approval before plan.","Examples contain account/project/bucket placeholders.","Container runtime is not installed by current Terraform modules."]})
        example(f"{cloud}-deployment-response","Deployment",{"id":f"dep_{cloud}_001","revision":1,"configuration":config,"state":"DRAFT","active_job_id":None,"latest_plan_id":None,"allowed_actions":["EDIT_CONFIGURATION","REQUEST_RECOMMENDATION"]})
        native={"schema_version":1,"cloud":cloud,"deployment_id":defaults[cloud]["deployment_id"],"metadata":{**defaults[cloud]["metadata"],"managed_by":"terraform","template_version":"v0-1","security_profile":"public-app-private-data-v1"},
            "compute":{"id":"example-vm-id","public_ip":"192.0.2.10","private_ip":"10.20.0.10" if cloud=="aws" else "10.30.0.10","identity":"example-workload-identity"},
            "database":{"id":"example-db-id","host":"example.private" if cloud=="aws" else "10.31.0.10","port":5432,"name":"app","tls_required":True},
            "cache":{"id":"example-cache-id","host":"example.redis.private" if cloud=="aws" else "10.31.1.10","port":6379 if cloud=="aws" else 6378,"tls_required":True,"auth_source":"external-secret-injection" if cloud=="aws" else "memorystore-get-auth-string-via-authorized-bootstrap"},
            "storage":{"id":"example-storage-id","name":"example-bucket"},"network":{"id":"example-network-id"},
            "pending_checks":["application-deployment","database-grants-and-schema","replication-connectivity","application-smoke-test"]}
        if cloud=="aws":
            native["database"]["admin_secret_ref"]="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:example"
            native["network"]["app_security_group_id"]="sg-example"
        else:
            native["database"].update(connection_name="example-project:asia-northeast3:example-db",app_db_user="example@example-project.iam",auth_mode="cloud-sql-iam-connector")
            native["cache"]["server_ca_certs"]=[]
            native["network"]["subnetwork_id"]="example-subnet-id"
            native["pending_checks"].append("cache-auth-delivery")
        example(f"{cloud}-handoff-response","Handoff",{"deployment_id":f"dep_{cloud}_001","applied_revision":2,"readiness":"RESOURCES_CREATED","container_runtime":"NOT_CHECKED","handoff":native})

    recommendation={"id":"rec_001","deployment_id":"dep_aws_001","based_on_revision":1,"status":"PROPOSED",
        "changes":[{"field":"sizing.compute_disk_gib","current_value":30,"proposed_value":40,"reason":"예시 추천. 실제 이미지·로그 사용량 확인 필요."}],
        "questions":[],"limitations":["No live price or quota query."],"created_at":"2026-11-03T00:00:00Z"}
    example("recommendation-response","Recommendation",recommendation)
    example("accept-recommendation-request","AcceptRecommendation",{"expected_revision":1,"recommendation_id":"rec_001","selected_fields":["sizing.compute_disk_gib"]})
    plan={"id":"plan_001","deployment_id":"dep_aws_001","config_revision":2,"template_version":"v0.1","status":"REVIEWABLE","review_digest":"sha256:"+'a'*64,
        "target_summary":"AWS 123456789012 / ap-northeast-2 / fox-aws-poc01","created_at":"2026-11-03T00:01:00Z","expires_at":"2026-11-03T00:16:00Z",
        "changes":[{"address":"module.ec2.aws_instance.this","resource_type":"aws_instance","action":"CREATE","summary":"t3.small, encrypted 40 GiB root disk, public web entry"}],
        "warnings":["Example only: real response must include all managed-resource changes."],"blockers":[],
        "cost_estimate":{"status":"NOT_AVAILABLE","message":"가격 계산 미구현. 무료라는 뜻이 아닙니다."},"approved_by":None,"approved_at":None}
    example("plan-response","Plan",plan)
    example("apply-request","ApplyRequest",{"expected_revision":2,"plan_id":"plan_001","review_digest":plan["review_digest"]})
    example("job-response","Job",{"id":"job_001","deployment_id":"dep_aws_001","type":"PLAN","status":"SUCCEEDED","phase":"DONE","message":"Plan ready for review","created_at":"2026-11-03T00:00:30Z","updated_at":"2026-11-03T00:01:00Z","result":{"kind":"plan","plan_id":"plan_001"},"error":None})
    example("stale-plan-error","Error",{"code":"PLAN_STALE","message":"설정 또는 실행 조건이 변경되어 새 plan이 필요합니다.","request_id":"req_001","issues":[{"code":"REVISION_CHANGED","field":"expected_revision","message":"현재 설정 revision이 검토한 plan과 다릅니다."}]})
    return {"contracts/provisioning.openapi.yaml":yaml.dump(spec,Dumper=ReadableDumper,allow_unicode=True,sort_keys=False,width=120),
            "contracts/examples/index.json":json.dumps(index,indent=2)+'\n',**examples}


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--check",action="store_true")
    args=p.parse_args()
    artifacts=make_artifacts()
    stale=[]
    for path,content in artifacts.items():
        target=ROOT/path
        if args.check:
            if not target.exists() or target.read_text(encoding="utf-8")!=content:
                stale.append(path)
        else:
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_text(content,encoding="utf-8",newline="\n")
    if stale:
        raise SystemExit("Stale generated contracts; run python tools/build_contract.py:\n"+'\n'.join(stale))
    print(f"{'Checked' if args.check else 'Wrote'} {len(artifacts)} contract artifacts (specification only).")


if __name__=="__main__":
    main()
