# 개인 PC 한 대 온프렘 준비

이 브랜치는 기존 AWS/GCP v1 API를 유지하면서 `/v2/environments`에 Ansible 실행기를 추가한다. 현재 구현 범위는 **등록된 Linux 호스트의 데이터 서비스 준비**다. 클라우드에서 데이터 복제, 앱 배포, 스키마 생성, 프록시 전환, Cloudflare 전환은 후속 연결이다. [전체 설계](on-prem-migration-design.md), [v2 API](../contracts/onprem.openapi.yaml).

## 구성과 준비 상태

- Ubuntu 24.04 / amd64, Python 3.12+, Docker Engine + Compose v2를 전제로 한다. Ansible은 일반 SSH 사용자로 실행하며 sudo나 OS 패키지 설치를 수행하지 않는다.
- PostgreSQL 17, Valkey 8.1, SeaweedFS 4.48을 이미지 digest로 고정한다. 프로토콜은 클라우드와 동일한 PostgreSQL·Redis·S3다. 클라우드 관리형 서비스의 HA/백업 기능까지 동일하다는 뜻은 아니다.
- SeaweedFS는 [object-migration release/1](https://github.com/SoftBank-2026-Hackathon-Foxtrot/object-migration/tree/release/1/deploy/seaweedfs)과 동일한 master/volume/filer/S3 단일 노드 구성이다. 외부 연결에는 S3 `8333`과 filer gRPC `18888`만 사용한다. master `9333`과 filer HTTP `8888`은 호스트에 노출하지 않는다.
- 한 PC가 app/database/cache/storage 역할을 함께 맡는다. 기존 컨테이너는 유지하고, 전용 runtime 디렉터리와 Compose 프로젝트만 관리한다. 데이터는 bind mount로 보존한다.
- DB는 TLS를 강제하고 controller에서 CA·IP SAN을 검증한다. `app_schema`는 앱 스키마 생성용, `app_writer`는 `NOLOGIN`으로 시작한다. 테이블·seed·복제 슬롯·publication은 만들지 않는다.
- Valkey는 AOF, 영속 ACL, `noeviction`, 1 GiB maxmemory다. `default`(관리)와 `app` 자격을 분리한다. S3도 migration/app 자격을 분리한다.
- `INFRA_READY`는 실제 컨테이너/인증/포트/TLS 점검 완료다. `READY`는 등록된 앱 주소의 HTTP 200 및 `X-Served-By`까지 일치해야 한다. 앱 미등록은 `NOT_CONFIGURED`이며 전체 `READY`로 표시하지 않는다. 컷오버 준비 여부는 판단하지 않는다.

## 로컬 실행

저장소 루트에서 실행한다. `setup_onprem.py`는 설정·비밀번호·SSH 키·90일 인증서를 새로 만들며 기존 출력 폴더를 덮어쓰지 않는다. 생성물은 Git에서 제외된 `.onprem-local/`에 저장한다. 개인키와 비밀번호를 저장소나 Notion에 붙여 넣지 않는다.

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-onprem.txt
export PATH="$PWD/.venv/bin:$PATH"
docker pull postgres:17-bookworm
docker pull valkey/valkey:8.1
docker pull chrislusf/seaweedfs:4.48
python tools/setup_onprem.py --local
python -m provisioner --config .onprem-local/config.json onprem-up \
  --request .onprem-local/request.json --idempotency-key pc-prepare-1
```

기본 요청은 `mode: plan`이므로 서비스 변경 전 사전 점검에서 멈춘다. 바로 준비하려면 **최초 요청 전에** 생성된 `request.json`의 mode를 `apply`로 바꾼다. 이미 생성한 환경은 API의 `apply` 명령으로 현재 plan을 적용한다. 기존 키로 mode만 바꿔 재전송하면 idempotency conflict가 발생한다.

`--local`은 명시적으로 허용한 로컬 검증 모드다. 주소는 `127.0.0.1`로 제한하며 handoff의 network scope는 `LOCAL_ONLY`다. 이것을 클라우드에서 접속 가능한 대상으로 등록하지 않는다. Tailscale 연결 전 로컬 데이터는 검증용으로만 사용한다.

API 서버는 기존 방식으로 실행한다. `PROVISIONER_TOKEN`은 24자 이상으로 설정한다.

```bash
python -m provisioner --config .onprem-local/config.json serve --host 127.0.0.1 --port 8070
```

`GET /v2/environments`에서 environmentId/revision/planId를 얻고, 다음 형태로 적용한다. 모든 변경 요청은 Bearer 인증과 `Idempotency-Key`가 필요하다.

```http
POST /v2/environments/{environmentId}/apply
Idempotency-Key: pc-apply-1
Authorization: Bearer <PROVISIONER_TOKEN>
Content-Type: application/json

{"expectedRevision":3,"planId":"plan-실제값"}
```

작업 상태는 `GET /v2/jobs/{jobId}`, 인프라·앱 준비 상태는 `GET /v2/environments/{environmentId}`에서 읽는다. API 입력은 refs만 받는다. 주소·SSH 옵션·원시 playbook·비밀번호를 API 요청에 넣을 수 없다.

## Tailscale과 SSH 연결

별도 사설 관리망을 요구하지 않는다. PC의 Tailscale IPv4를 `address`와 `serviceAddress`에 함께 사용한다. 클라우드 라우터는 기존 `environments/tailscale/{aws,gcp}` 구성과 연결한다. Tailscale 설치·로그인과 SSH 서버 설치는 관리자 권한이 필요한 별도 호스트 준비다. [공식 Linux 설치](https://tailscale.com/docs/install/linux), [Ubuntu 24.04 패키지 저장소](https://pkgs.tailscale.com/stable/#ubuntu-noble).

현재 PC에 SSH/Tailscale이 없다면 사용자가 터미널에서 다음을 실행한다.

```bash
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt-get update
sudo apt-get install -y tailscale openssh-server
sudo systemctl enable --now tailscaled
sudo tailscale up
tailscale ip -4
cat /etc/ssh/ssh_host_ed25519_key.pub
```

tailnet ACL에서 controller→PC `22,5432,6379,8333,18888`, 데이터 모듈→해당 데이터 포트를 허용한다. 앱 포트는 실제 binding을 정한 후 추가한다. 공유기의 공개 포트 포워딩은 필요 없다. SSH 로그인은 이 작업의 공개키를 `authorized_keys`에 등록해 사용한다. 대상 사용자는 기존 Docker 접근 권한이 있어야 한다.

controller에서 실제 대상의 host key를 직접 확인한 뒤 새 출력 경로로 준비한다.

```bash
python tools/setup_onprem.py --address 100.x.y.z --ssh-user <사용자> \
  --host-key 'ssh-ed25519 <호스트의 실제 공개키>' --uid 1000 --gid 1000 \
  --runtime-root /home/<사용자>/.local/share/foxtrot-onprem-remote \
  --output /안전한경로/onprem-remote
```

새로 생성된 `secrets/ssh_key.pub`를 대상 사용자에게 등록하고 개인키는 controller에 둔다. 확인되지 않은 `ssh-keyscan` 결과를 자동 신뢰하지 않는다. SSH host key를 바꾸거나 secret·inventory·image·playbook이 바뀌면 기존 plan을 적용할 수 없다. plan 유효기간은 기본 15분이다.

로컬 검증 환경의 등록 정보는 불변이다. Tailscale용 환경은 새 inventory/runtimeRoot로 준비한다. 로컬 검증 데이터의 자동 인수·이동은 제공하지 않으며 로컬 서비스 종료는 아래 cleanup을 사용한다. **같은 PC에서 로컬→Tailscale 전환 시 기존 검증 환경과 운영 환경을 구분해야 한다.** 운영 환경은 controller journal에서도 새 사이트/호스트 예약을 검토해 등록한다.

## 앱 연결과 복구

운영자 catalog의 `bindings`에 `orgs`, `hostId`, `port`, `healthPath`, `expectedServedBy`를 등록하고 최초 요청에 `appBindingRef`를 넣는다. 예: port `18080`, healthPath `/readyz`, expectedServedBy `onprem-app`. 앱은 이 값의 `X-Served-By`를 응답해야 한다. 현재 앱 포트 8000처럼 기존 서비스와 충돌하는 주소는 사용하지 않는다. 앱 이미지 배포 및 앱 소유 schema hook 연결은 후속 COMPUTE 작업이다.

프로세스 중단 후 실행 중이던 작업은 `NEEDS_RECONCILIATION`으로 남기고 자동 재실행하지 않는다. `reconcile`은 실제 소유권·이미지·서비스를 관찰한다. 소유권이 확인된 미완료 환경은 `FAILED`/`NOT_READY`로 정리하여 명시적인 새 plan을 허용한다. 소유권이나 실제 결과를 확인하지 못하면 계속 `NEEDS_RECONCILIATION`이다.

서비스 종료는 `plan`에 `intent: cleanup`을 보낸 뒤 그 plan을 `apply`한다. Compose `down`만 실행하며 데이터·자격·host reservation은 보존한다. workflow가 연결된 환경은 cleanup을 거절한다. 데이터 삭제, 다른 환경으로의 소유권 이전, 기존 호스트의 무조건적인 덮어쓰기는 제공하지 않는다.

## 최소 관측 정보와 남은 연결

API는 environment/workflow/job ID, revision, 단계·호스트, 시작/종료/관측 시각, 실패 코드, 인프라·앱 상태를 제공한다. raw Ansible 로그나 secrets는 응답하지 않는다. Ansible plan의 변경 수는 `null`이며 Terraform과 동일한 확정 변경 계획이라고 표시하지 않는다.

아직 연결되지 않은 항목은 handoff `pendingChecks`에 남긴다: 앱 스키마 hook/HOLD 기동, 클라우드→SELF_MANAGED PG17 프로필, 데이터 어댑터 등록 및 fence 검증, CP 등록·마이그레이션 준비 gate, Cloudflare origin. v2의 CP/OTLP 자동 전송은 후속 observability 통합이 필요하다. 기존 v1 전송은 이 브랜치에서 변경하지 않는다.

Ansible 실행은 [Runner Python API](https://docs.ansible.com/projects/runner/en/stable/python_interface/)를 사용한다. 컨트롤러는 하나의 journal당 하나만 실행한다. 현재 journal은 단일 controller용이며 여러 독립 controller의 같은 호스트 동시 준비는 지원하지 않는다.
