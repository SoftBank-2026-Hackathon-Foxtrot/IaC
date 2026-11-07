# 프로비저닝 인터페이스 v0.3 — 관리 중인 환경의 사양 조정

**목표: 이미 플랫폼이 관리하는 이전 대상 환경에 필요한 사양값만 조정하고, 확인한 Terraform 계획을 실행한다.**

원본·대상 환경의 배포 코드와 기본 설정은 준비되어 있다. 인프라를 탐지하거나 AWS 코드를 GCP 코드로 변환하지 않는다. 대상 클라우드의 관리 코드를 그대로 사용한다.

**현재 구현:** Terraform 모듈, 입력 검증·병합 함수, 이 인터페이스 명세와 예시. API 서버·AI 호출·실행기는 아직 없다. HTTP 기능은 기존 플랫폼 백엔드에 붙이면 된다.

## 시작할 때 이미 있는 것

| 플랫폼이 관리하는 것 | 프로비저닝 파트가 사용하는 방식 |
|---|---|
| migration_id → 원본/대상 environment_id | 원본은 참고용, 실행은 대상만 |
| 환경별 Terraform root·Git revision·provider lock | 관리 중인 대상 코드를 선택 |
| 환경별 baseline 설정·이미지·IAM·네트워크·태그 | 기존 값을 유지하고 sizing만 병합 |
| 환경별 state backend·클라우드 인증·secret 연결 | 서버 내부에서 사용. UI에 다시 입력받지 않음 |

이 정보가 없으면 플랫폼의 사전 준비가 필요한 상태다. 이 API에 환경 등록, 템플릿 탐색, 코드 업로드, state import 기능은 만들지 않는다. 실제로 존재하는 대상 자원은 **그 자원을 관리하는 기존 state**로 접근한다. 빈 state로 새 환경을 만들지 않는다.

## 사용자가 보는 흐름

```mermaid
flowchart LR
  P[플랫폼의 기존 마이그레이션] --> C[대상 현재값·선택지 조회]
  C --> U[UI에서 일부 사양 조정]
  U --> R[선택 사항: AI 추천]
  R --> U
  U --> M[대상 baseline에 변경값만 병합]
  M --> T[Terraform plan]
  T --> V[전체 변경 목록 확인]
  V --> A[같은 saved plan 실행]
  A --> O[상태·인프라 출력 인계]
```

원본의 EC2 타입을 GCP에 복사하지 않는다. 예를 들어 AWS → GCP이면 이미 있는 GCP baseline에 `compute_machine_type: e2-medium`만 덮어쓴다. 변경하지 않은 값은 **대상 baseline 값**을 유지한다.

UI는 입력 중인 값과 추천 채택을 자체 상태로 관리한다. 추천은 값을 저장하거나 실행하지 않는다. UI는 선택한 추천값과 직접 입력한 값을 같은 `overrides`로 보낸다. 설정 초안 CRUD, 추천 채택 전용 API, 설정 revision API는 없다.

## API 4개

공통 경로: `/api/v1/provisioning`. 타입은 [OpenAPI](../contracts/provisioning.openapi.yaml), 완전한 예시는 [예시 목록](../contracts/examples/index.json)에 있다.

| 호출 | 입력 → 출력 |
|---|---|
| GET `/migrations/{migration_id}` | 기존 이전 작업 ID → 원본/대상 식별자, 대상 현재 sizing, 선택지 JSON Schema |
| POST `/migrations/{migration_id}/plans` | overrides → PLAN job (202) |
| POST `/plans/{plan_id}/apply` | 검토한 plan ID, 본문 없음 → APPLY job (202) |
| GET `/jobs/{job_id}` | job ID → 진행 상태, 완료 시 plan 또는 handoff |

계정·리전·코드 경로·인증·secret·이미지 ID는 요청 필드가 아니다. 서버가 migration_id의 대상 연결에서 가져온다. 원본/대상 선택은 기존 플랫폼 흐름의 책임이다.

**AWS 대상 plan 요청 예시:**

```json
{"overrides": {"compute_instance_type": "t3.medium", "compute_disk_gib": 40}}
```

GCP 대상은 `{"overrides": {"compute_machine_type": "e2-medium"}}`. 변경할 값이 없으면 `{"overrides": {}}`를 보낸다. UI는 `sizing_schema`로 폼을 만들고 서버는 실제 대상 cloud 기준으로 다시 검사한다. 공통 OpenAPI의 `Sizing`만 검사해서 다른 클라우드 필드를 허용하면 안 된다.

로컬에서 동일한 입력 경계를 확인할 수 있다.

```bash
python -m control_plane.deployment.tools.render_inputs context --cloud gcp --base environments/gcp/deployment.example.tfvars.json
python -m control_plane.deployment.tools.render_inputs render-overrides --cloud gcp --base environments/gcp/deployment.example.tfvars.json --request contracts/examples/gcp-plan-request.json --output reviewed.tfvars.json
```

적용 후 플랫폼이 VM 출력을 등록하고 [COMPUTE](../compute/README.md)에 `targetRef`를 넘긴다.

## 내 파트의 처리

1. **사양 조회:** IaC는 대상의 현재값과 허용 범위를 제공한다. AI 추천과 사용자 선택은 컨트롤 플레인이 처리한다.
2. **검증·병합:** `merge_overrides(target_cloud, target_baseline, overrides)`로 일부 값만 합친다. 필드·타입·범위뿐 아니라 DB 용량과 자동 확장 상한 등 병합 후 조건도 검사한다. baseline과 원본 환경은 변경하지 않는다.
3. **계획:** 대상의 관리 코드·state로 plan을 만들고 민감값을 제거한 전체 변경 목록과 최종 sizing을 반환한다. UI 입력은 이후 달라져도 이 plan은 불변이다. 재계획하면 새 ID를 만들고 이전 계획은 무효화한다.
4. **실행·인계:** 사용자가 확인한 plan ID로 저장된 계획을 실행하고, 성공한 최종 설정을 플랫폼의 대상 baseline에 반영한다. 완료 job에 `terraform output -json handoff`만 넣어 앱 배포·DB 이전 모듈에 전달한다.

기존 `render_inputs.py`의 CLI는 로컬 입력 파일 생성용으로 유지한다. `merge_overrides`는 서버가 재사용할 입력 처리 함수이며, 환경 조회·AI·Terraform 실행·baseline 저장을 구현한 함수가 아니다.

## 실행에 필요한 최소 규칙

- **대상만 실행:** 플랫폼 권한을 재사용해 migration/plan/job 접근과 대상 실행 권한을 확인한다. 원본 state에 apply하지 않는다. 대상은 트래픽 전환 전 준비 단계여야 한다. 이미 트래픽을 받은 뒤의 변경은 이번 흐름 밖이다.
- **검토한 계획 실행:** plan ID에 실제 대상, 병합된 설정, 코드·provider·이미지·secret 참조 버전, state를 고정한다. 관련 조건이 바뀌거나 계획이 만료되면 409 `PLAN_STALE`로 재계획한다. 기본 유효기간은 15분이다. 서버 내부 기록이므로 UI가 hash/revision을 조립하지 않는다. 외부 drift는 state serial만으로 완전히 감지할 수 없다.
- **예상한 변경만:** 사양 조정에 따른 변경과 관리 baseline에서 예정한 생성만 허용한다. 원본 변경, 무관한 drift 수정, 삭제·교체는 `BLOCKED`다. 기존 대상의 사양 변경은 재시작을 요구할 수 있으므로 plan에 표시한다. 무중단 변경을 보장하지 않는다.
- **중복 실행 방지:** plan/apply에 `Idempotency-Key`를 받는다. 권한 확인 후 같은 호출자·경로·key·본문은 같은 job을 반환하고 다른 본문은 409다. 키가 달라도 같은 plan은 한 번만 실행한다. **같은 대상 환경**은 여러 migration에서 요청해도 한 번에 하나만 plan/apply하며 state 잠금도 유지한다.
- **실패 구분:** plan 실패는 `FAILED`. apply가 부분 완료되었거나 결과를 모르면 `NEEDS_RECONCILIATION`으로 수동 확인한다. 자동 destroy·재apply하지 않는다. 자원은 적용됐지만 baseline/결과 저장에 실패한 경우도 같다. plan 생성 성공과 정책상 실행 가능은 별개이므로 job이 SUCCEEDED여도 plan의 BLOCKED 여부를 확인한다.

진행은 `QUEUED → RUNNING → SUCCEEDED / FAILED / NEEDS_RECONCILIATION`. UI는 job을 polling하고, 성공한 PLAN의 result는 Plan, 성공한 APPLY의 result는 Handoff다. 대기·실행·실패 시 result는 null이며 실패 원인은 error로 전달한다. 중복 실행을 막는 검사와 작업 등록은 서버가 원자적으로 처리해야 한다.

handoff의 `INFRA_APPLIED`는 인프라 반영 완료다. 앱 실행·컨테이너 런타임·DB 복제·트래픽 전환 검증은 포함하지 않는다. 실제 endpoint/identity/네트워크와 `pending_checks`의 의미는 [플랫폼 출력 계약](platform-contract.md#출력)을 따른다. 전체 state/plan/로그나 비밀값을 UI·AI에 반환하지 않는다.

## 담당과 남은 합의

| 담당 | 이번 연결 지점 |
|---|---|
| 프로비저닝 | 허용 사양, 검증·병합, plan/apply, 상태·출력 계약 |
| 플랫폼 백엔드 | 기존 migration → 환경 코드·baseline·state·인증 연결, 권한, job 실행·저장 |
| UI | 사양 폼, 추천 선택, 계획 확인, job polling |
| 앱·DB 이전 모듈 | handoff 소비, 앱 배포·DB 초기화/복제와 준비 검증 |

팀에서 정할 것은 **기존 환경 정보를 가져올 함수/저장 위치**, **실행기를 붙일 담당과 위치**, **첫 데모에서 사용자에게 열 사양 항목**이다. 현재 후보는 카탈로그의 서버·DB·캐시 사양/용량/HA 항목이며, 다른 설정은 관리 baseline에 고정한다.

v0.1의 신규 배포 초안 관리 계약을 이 문서가 대체한다. 템플릿 목록/승인, 이미지 레지스트리, 설정 저장·버전, 추천 채택, 별도 plan/handoff 조회 API는 제거했다. Terraform 모듈 자체의 버전은 v0.1을 유지한다.

## 명세 검증

`python -m control_plane.deployment.tools.build_contract`로 카탈로그 기반 OpenAPI·예시를 생성한다. `--check`와 `python -m unittest discover -s tests -v`로 형식·입력 경계를 검사한다. 서버의 권한·동시성·실제 클라우드 변경을 검증한 결과는 아니다.
