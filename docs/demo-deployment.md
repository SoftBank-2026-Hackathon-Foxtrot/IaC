# 치이카와 LIVE 연결 — PoC 배포 담당용

기준: demo `cd9904d`, redis-migrator `8912b44`. 기존 AWS/GCP 코드와 state를 사용하고, 사용자 API는 sizing 조정 5개를 유지한다.

## 이번 IaC 반영

- 양쪽 Redis: `notify-keyspace-events=KEA`, `maxmemory-policy=noeviction`. AWS는 전용 parameter group, GCP는 redis_configs로 설정한다. Cluster 모드는 사용하지 않는다.
- `proxy_cidrs`: 앱 → 기존 중앙 Redis 프록시 TCP 6379 / PgBouncer TCP 6432. 기본 `[]`.
- AWS `migration_source_cidrs`: 관리 환경 → RDS TCP 5432 / ElastiCache TLS TCP 6379. 기본 `[]`. DB/cache가 관측하는 원본 주소를 넣는다. 라우터 SNAT가 있으면 라우터의 사설 주소다.
- `enable_cloudflare_tunnel`: 앱 VM의 outbound TCP/UDP 7844 허용. 기본 false. true이면 목적지 IPv4 전체에 해당 포트만 허용한다. cloudflared 설치·터널 등록은 배포 담당이 수행한다.

CIDR은 RFC1918 또는 Tailscale 범위의 /24~32만 받는다. 실제 호스트 /32를 우선 사용한다. 이 값들은 플랫폼 baseline 설정이며 AI/API overrides로 변경할 수 없다.

예를 들어 기존 AWS baseline에 아래 필드를 병합한다. 주소는 설명용이며 실제 환경 주소로 바꾼다. GCP는 migration_source_cidrs를 제외한 두 필드만 사용한다.

```json
{
  "proxy_cidrs": ["10.50.0.10/32"],
  "migration_source_cidrs": ["10.20.10.5/32"],
  "enable_cloudflare_tunnel": true
}
```

**방화벽 허용과 라우팅은 별개다.** 기존 관리 환경의 VPN/Tailscale subnet router, DNS, SNAT/복귀 경로가 먼저 있어야 한다. 이 모듈은 해당 라우터를 새로 배포하지 않는다. 앱이 Tailscale을 직접 쓰는 경우 호스트의 overlay egress 정책도 별도로 준비한다. GCP 앱 SA 대상 firewall은 관리형 DB/Redis의 ingress 방화벽이 아니다. 관리망에서 PSA 대역까지 도달하는 라우터/peering 경로는 네트워크 담당이 검증한다.

## 앱과 DB 연결

1. 기존 secret 관리 방식으로 앱 DB 역할을 준비한다. RDS는 별도 앱 역할, Cloud SQL은 기존 IAM DB 사용자 또는 DB 팀이 선택한 PgBouncer 인증 방식을 연결한다. Terraform DB 생성만으로 SQL 권한이 생기지는 않는다.
2. **앱 전용 DB**에 관리자로 접속해 [bootstrap-grants.sql](../examples/demo/bootstrap-grants.sql)을 `-v app_role=<실제 앱 역할>`로 실행한다. 역할/암호를 만들거나 데이터를 비우지 않는다. 현재 앱은 시작 시 CREATE TABLE/INDEX IF NOT EXISTS를 실행하므로 public 스키마 CREATE 권한을 준다. 기존 테이블이 다른 역할 소유이면 필요한 DML 권한도 부여한다. 추후 별도 스키마 배포로 분리하면 런타임 CREATE 권한을 회수한다.
3. 앱·worker의 DATABASE_URL은 PgBouncer, REDIS_URL은 중앙 Redis 프록시로 지정한다. DB 이름은 Terraform의 database_name과 맞춘다. 실제 Redis 인증값은 프록시/이전기만 보관하고 앱에는 프록시 자격 증명만 준다. 기존 앱→데이터 SG 경로가 남아 있으므로 이 자격 증명 분리가 필수다.
4. Cloud SQL IAM 토큰 갱신/connector 및 TLS, RDS 서버 TLS는 DB 배포 담당이 구성한다. Redis backend는 AWS 6379 / GCP 6378의 TLS endpoint를 사용한다. 인증서 검증을 끄지 않는다.
5. DB 이전 registry에 `chat_messages`를 추가하고, 대상 테이블·인덱스와 앱 권한을 복제 시작 전에 준비한다. `/seed`는 데이터를 초기화하므로 이전 대상 초기화에 사용하지 않는다.

## WebSocket·관리 프로세스

- 앱 명령에 `--ws-max-size 4096` 포함. 웹과 `/api/live/chat`은 같은 내부 포트 8000이다. WebSocket 전용 공개 포트를 추가하지 않는다. cloudflared가 같은 VM/Compose 네트워크에서 앱으로 연결하게 한다.
- 앱은 Origin과 Host를 비교하므로 Tunnel의 Host를 내부 이름으로 덮어쓰지 않는다. 외부 공개 도메인을 유지한다.
- heartbeat 15초, 클라이언트 무응답 감지 45초를 고려한다. 트래픽 가중치 변경은 열린 WebSocket을 새 앱으로 이동시키지 않는다. 원본 앱 종료 전 연결을 정리하고 재접속·history 복원을 확인한다.
- proxy·syncworker·statemig는 각각 1개. 기존 관리 VM이면 proxy/statemig가 같은 영속 디스크 디렉터리를 `/state`로 공유한다. ECS 배치라면 같은 EFS 접근 지점을 사용한다. 앱마다 프록시를 복제하거나 이전 중 관리 프로세스를 재배포하지 않는다.
- 관리 포트 7000/7100/8090은 관리 환경 내부에서만 연다. 이번 앱용 SG/firewall에는 공개하지 않는다.

## 연결 완료 확인

- 양쪽 Redis에서 이전기의 precheck 통과: keyspace/만료 이벤트 수신, noeviction, 데이터 용량 여유. AWS `apply_immediately=false`이므로 계획 반영 시점과 실제 적용값도 확인한다.
- 양쪽 앱에서 로그인·채팅 송수신·주문·영수증 확인. 앱 `/readyz`만으로 DB/Redis 이전 성공을 판정하지 않는다.
- Redis 컷오버/롤백과 앱 트래픽 전환을 각각 검증한다. demo의 로컬 Compose 결과는 클라우드 통합 검증 결과가 아니다.

CI는 mock plan과 입력 계약만 검증한다. 실제 사설 경로, SQL 권한, proxy TLS, Cloudflare WebSocket 연결은 대상 환경에서 확인해야 한다.
