# Cowry 설계

> 상태: 초안 (개정 1) · 2026-09-27
> 범위: phase 1(로컬 전용 macOS 앱) 상세 설계, phase 2–3 방향

## 0. 요약

Cowry는 Apple 플랫폼 네이티브, local-first 복식부기 장부 앱이다.

- **Swift 단일 언어.** AppKit 앱과 `CowryKit` 패키지로 구성하고, 저장소는 GRDB(SQLite)를 쓴다.
- **전체 장부를 막힘 없이 탐색한다.** 10년 치 거래를 페이지 나눔 없이 스크롤하고, 필터하고, 검색한다. 목록은 가상화된 `NSTableView`로 그린다.
- **UI와 장부 런타임을 분리한다.** UI가 아는 것은 런타임의 공개 API(커맨드, 스냅샷 읽기, 변경 스트림)뿐이다. 이 경계는 모듈과 접근 제어로 컴파일러가 강제한다.
- **op 로그가 유일한 진실의 원천이다.** 모든 변경은 불변 op로 기록되고, 테이블은 op를 재생한 결과다. 그래서 로그 자체가 편집 이력이다.
- **싱크는 중앙 선형 로그 위에서 rebase한다.** 원격 main 로그의 순서는 조건부 append(CAS)로 정한다. 로컬의 미반영 op는 새 main 위에서 다시 적용한다.
- **충돌은 막지 않고 자동으로 해결한 뒤 기록한다.** 결정적인 기본 정책(필드 단위 3-way merge, 작성 시각 기준 LWW 등)으로 해결하고, 결과를 충돌 로그에 남긴다. 사용자는 로그를 보고 나중에 고칠 수 있다. 구조적 불변식은 어떤 경우에도 깨지지 않는다.
- **해시 체인과 상태 다이제스트로 검증한다.** 해시 체인은 로그의 변조와 손상을, 상태 다이제스트는 기기 간 재생 결과가 어긋나는 것을 탐지한다.
- **다중통화를 지원한다.** 기록은 원래 통화로 하고, 평가는 조회 시점에 primary currency로 한다. 통화가 섞인 거래는 환전 계정으로 통화별 균형을 맞춘다.
- **전송 계층은 프로토콜 뒤에 둔다.** phase 1은 로컬 전용이며, 싱크 로직은 인메모리 원격으로 테스트한다. CloudKit은 phase 2에 붙인다.

## 1. 원칙

1. **Local-first.** 기기의 SQLite가 항상 완전한 사본이다. 클라우드는 중계소이지 데이터의 주인이 아니다. 네트워크 없이도 모든 기능이 동작한다.
2. **한 가지만 잘한다.** 앱이 하는 일은 기록, 검증, 조회, 평가, 싱크다. 은행 연동, 예산, 투자 분석은 범위 밖이다. 가져오기는 외부 도구가 만든 결과를 받는 방식으로 한다(phase 3).
3. **구조적 불변식은 구조로 지킨다.** 균형이 맞지 않는 거래, 존재하지 않는 계정을 가리키는 참조, 순환하는 계정 트리는 어떤 경로로도 생기지 않아야 한다.
4. **op는 결정을 담고, 재생은 결정하지 않는다.** 할 때마다 결과가 달라질 수 있는 일은 op를 만들 때 끝내고, 그 결과를 op에 기록한다.
   - 예: 현재 시각, 새 UUID, 환전 포스팅 생성, 충돌 해결.
   - 재생은 `(상태, op) → 상태`의 순수 함수다.
5. **사실과 캐시를 구분한다.** op 로그에 들어가 싱크되는 것은 사용자가 입력한 사실뿐이다. 시세 캐시, 인덱스, 합계는 로컬에서 언제든 다시 만든다.
6. **작성할 때는 엄격하게, 병합할 때는 관대하게.** 로컬 입력은 모든 규칙으로 검증한다. 다른 기기의 변경과 병합할 때는 아무것도 거부하지 않는다. 결정적 정책으로 해결하고 그 결과를 기록한다.

## 2. 아키텍처

### 2.1 모듈

```
CowryKit (Swift Package)
├─ LedgerCore     도메인 타입 · op 정의 · 검증 · 병합 정책 · 금액 연산 · 다이제스트
│                 Foundation + CryptoKit만 사용, I/O 없음
│                 PriceProvider, LogRemote 프로토콜 정의
├─ Ledger         런타임: 저장(GRDB) · op 적용 · 스냅샷 읽기 · 변경 스트림 · 평가 · 싱크 엔진
├─ Pricing        PriceProvider 구현 (ECB). 네트워크 코드는 여기에만 둔다
└─ CloudKitSync   (phase 2) LogRemote의 CloudKit 구현

Cowry.app         AppKit (macOS). 조립(composition root)
(iOS 앱)          phase 2에서 싱크와 함께 UIKit으로. CowryKit은 그대로 공유한다
```

```
              Cowry.app
         ┌───────┼────────┐
       Ledger  Pricing  CloudKitSync
         └───────┼────────┘
             LedgerCore
```

어댑터(`Pricing`, `CloudKitSync`)는 `LedgerCore`에만 의존한다. 앱이 어댑터를 만들어 `Ledger`에 주입한다.

### 2.2 분리를 강제하는 장치

- **GRDB를 숨긴다.** `Ledger`는 GRDB를 `internal import GRDB`(SE-0409)로 가져온다. GRDB 타입이 공개 API에 드러나면 컴파일 에러가 난다.
- **검증된 값은 런타임만 만든다.** `Entry`, `Account` 같은 검증된 도메인 값의 생성자는 `package` 접근 수준이다. 앱이 만들 수 있는 것은 `EntryDraft` 같은 초안뿐이다.
- **런타임은 네트워크를 모른다.** 시세와 원격 저장소는 `LedgerCore`의 프로토콜을 통해 주입받는다.
- **UI와 런타임의 경계는 세 가지뿐이다.**
  - 커맨드: op 하나를 만든다.
  - 스냅샷 읽기: 일관된 한 시점의 데이터를 읽는다.
  - 변경 스트림: 무엇이 바뀌었는지 알려준다.
  - 이후 CLI나 iOS UI도 이 API 위에 얇은 어댑터로 올린다.

### 2.3 런타임 API (스케치)

```swift
public final class Ledger: Sendable {
    public init(at url: URL, device: DeviceID) throws

    // 커맨드: 각각 op 하나를 만들어 적용한다
    public func post(_ draft: EntryDraft) async throws -> Entry
    public func amend(_ id: Entry.ID, to draft: EntryDraft) async throws -> Entry
    public func void(_ id: Entry.ID) async throws
    public func openAccount(_ draft: AccountDraft) async throws -> Account
    public func closeAccount(_ id: Account.ID, on date: LocalDate) async throws
    // … op 종류마다 하나 (§6.2)

    // 읽기와 변경
    public func snapshot() -> LedgerSnapshot
    public func changes() -> AsyncStream<LedgerChange>

    // 외부 세계
    public func refreshPrices(using providers: [any PriceProvider]) async throws
    public func sync(with remote: any LogRemote) async throws -> SyncReport   // phase 2
}

/// 한 시점에 고정된 읽기 전용 뷰. 모든 메서드는 동기이며 빠르다(목록 데이터소스에서 호출).
public struct LedgerSnapshot: Sendable {
    public func journal(_ filter: JournalFilter) throws -> JournalIndex        // 정렬된 키 배열
    public func entries(_ ids: some Collection<Entry.ID>) throws -> [Entry]    // 배치 읽기
    public func register(of account: Account.ID) throws -> Register            // 누적 잔액 포함
    public func accounts() throws -> AccountTree
    public func balances(asOf date: LocalDate) throws -> [Account.ID: Holdings]
    public func valuation(of holdings: Holdings, in target: Commodity.ID,
                          asOf date: LocalDate) throws -> Valuation
    public func diagnostics() throws -> [Diagnostic]
    public func conflicts() throws -> [ConflictRecord]
    public func history(of target: EntityID) throws -> [OpRecord]              // 편집 이력
}

/// op가 적용될 때마다(로컬 커맨드든 싱크든) 발행된다.
public struct LedgerChange: Sendable {
    public let snapshot: LedgerSnapshot
    public let entries: ChangeSet<Entry.ID>          // inserted · updated · removed
    public let accounts: ChangeSet<Account.ID>
    public let commodities: ChangeSet<Commodity.ID>
    public let prices: Bool
}

public typealias Holdings = [Commodity.ID: Int64]
```

### 2.4 동시성

- **런타임 객체.** `Ledger`는 GRDB `DatabasePool`을 감싼 `Sendable` 클래스이고, actor가 아니다.
- **쓰기.** 모든 쓰기는 GRDB의 단일 writer를 거친다. 따라서 로컬 커맨드와 싱크 적용은 자연히 직렬화된다.
- **읽기.** 읽기는 WAL 스냅샷 위에서 한다. 내부적으로는 GRDB `DatabaseSnapshotPool`을 쓴다.
  - WAL 모드에서는 읽기가 쓰기를 기다리지 않는다. 그래서 메인 스레드에서 작은 배치를 동기로 읽어도 된다.
  - 오래된 스냅샷을 쥐고 있으면 WAL 체크포인트가 막힌다. UI는 새 변경을 받으면 이전 스냅샷을 곧바로 놓는다.
- **변경 스트림.** 변경 이벤트는 op를 적용하는 과정에서 나온다. op를 적용할 때 바뀐 행이 `op_undo`에 기록되므로, 바뀐 ID 집합이 비용 없이 정확하게 나온다. 쿼리를 다시 돌려 비교하는 방식(GRDB `ValueObservation`)은 목록 갱신에 쓰지 않는다.
- **LedgerCore.** 스레드도, 비동기 런타임도 만들지 않는다.

## 3. 도메인 모델

### 3.1 값 타입과 정규화

| 값 | 표현 | 규칙 |
|---|---|---|
| 금액 | `Int64` 최소 단위 | `commodity.scale`로 해석한다. 부동소수점은 쓰지 않는다 |
| 날짜 | `LocalDate` (`YYYY-MM-DD`) | `Foundation.Date`는 쓰지 않는다. 장부의 날짜는 달력 날짜이므로 타임존이 바뀌어도 밀리지 않아야 한다 |
| ID | UUID | 일반 엔티티는 UUIDv7을 쓴다. ISO 통화와 시스템 계정은 UUIDv5로 결정적으로 만든다. DB에는 소문자 문자열로, 다이제스트에는 16바이트로 넣는다 |
| 문자열 | NFC로 정규화하고 앞뒤 공백을 제거한다. 빈 문자열은 `nil`로 바꾼다 | 한글은 NFC와 NFD가 섞여 들어올 수 있다. Swift `==`는 둘을 같다고 보지만 SQLite는 바이트로 비교한다 |
| 시세 | 10진 문자열 → `Decimal` | 작성할 때 정규형(지수 표기 없음, 끝의 0 제거)으로 만들고, 그 문자열 그대로 저장한다 |
| 작성 시각 | HLC | §6.1 |

정규화는 초안이 검증된 값으로 바뀌는 지점에서 한 번만 한다.

### 3.2 부호 규약

- 차변은 +, 대변은 −다. 모든 거래는 통화별 합이 0이다.
- 부채·자본·수익 계정의 정상 잔액은 음수다. 표시할 때만 부호를 뒤집는다.

### 3.3 엔티티

| 엔티티 | 필드 | 비고 |
|---|---|---|
| Commodity | code, kind(currency · security · crypto · other), **scale**, name, quote, feed | `scale`은 바꿀 수 없다. quote는 시세의 기준 통화다(AAPL → USD) |
| Account | **type**(asset · liability · equity · income · expense), parent, name, role, opened_on, closed_on, archived, deleted, merged_into, sort_order, note | `type`은 바꿀 수 없고, 자식은 부모와 같은 type이다. 전체 경로는 저장하지 않는다. `deleted`는 톰스톤이다 |
| Entry | date, created_at, payee, memo, postings(≥ 2) | posting은 (account, commodity, amount)다 |
| Price | base, quote, date, rate | 사용자가 직접 입력한 시세만 둔다 |
| BalanceAssertion | account, commodity, date, amount | "date가 시작되는 시점의 잔액"을 뜻한다 |
| Setting | key, value | `primary_commodity` 등 |

**시스템 계정.** `Equity:Conversion`(role = conversion)과 `Equity:Opening Balances`(role = opening_balance)는 장부를 만들 때 결정적 UUIDv5로 생성한다.

**결정적 ID로 만드는 op는 멱등이다.** 같은 ID의 엔티티가 이미 있고 내용이 같으면 아무 일도 하지 않는다. 그래서 두 기기가 각자 KRW나 시스템 계정을 만들어도 충돌하지 않는다.

### 3.4 장부 = 파일 = 존

장부 하나는 SQLite 파일 하나이고, phase 2부터는 CloudKit 커스텀 존 하나이기도 하다. 여러 장부(개인용, 사업용 등)는 서로 완전히 독립적이다.

## 4. 다중통화와 평가

### 4.1 원칙

- **기록은 원래 통화로, 평가는 조회할 때 한다.** primary currency는 설정일 뿐이다. 바꿔도 데이터는 그대로이고 화면만 다시 계산된다.
- **실제 거래 환율과 공개 시세는 다른 것이다.**
  - 실제로 적용된 환율은 거래의 사실이므로 거래 안에 기록된다.
  - 공개 시세는 보유 자산을 평가하는 데만 쓴다.
  - 예: 해외결제 50달러가 카드로 68,650원 청구됐다면, 그날 공개 환율이 얼마였든 68,650원이 진실이다.

### 4.2 환전 계정 (trading accounts)

통화가 섞인 거래는 런타임이 `Equity:Conversion`으로 가는 포스팅을 자동으로 만든다.

```
2026-09-20  Apple Store
  Expenses:쇼핑              50.00 USD
  Liabilities:신한카드    -68,650 KRW
  Equity:Conversion         -50.00 USD   ← 자동
  Equity:Conversion        68,650 KRW    ← 자동
```

**생성 규칙.** 초안에서 합이 0이 아닌 통화를 모두 찾는다.
- 그런 통화가 **하나뿐**이면 사용자 오류(균형 불일치)다.
- **둘 이상**이면 통화 `c`마다 `(Conversion, c, −Σc)` 포스팅을 추가한다.
- 이 생성은 초안을 `Entry`로 바꿀 때 일어나고, 생성까지 마친 최종 포스팅이 op에 저장된다(원칙 4).

**UI 표시.** 환전 포스팅은 숨긴다. 대신 "50 USD · ₩68,650 (1,373원/$)"처럼 암시된 환율을 보여준다.

**이 방식을 고른 이유**
- **불변식이 정수 비교 하나다.** 통화별로 `SUM(amount) = 0`인지만 보면 된다. 반올림 허용오차 규칙이 필요 없다.
- **환산한 재무상태표가 항상 맞는다.** 통화마다 합이 0이므로, 모든 계정을 같은 환율로 평가하면 전체 합이 0이다.
- **환차손익이 저절로 나온다.** `Equity:Conversion`을 primary currency로 평가한 값이 곧 누적 환차손익이다. 주식이라면 평가손익이다.
  - 예: 100만 원을 730달러로 바꾼 뒤 환율이 1,500원이 되었다.
  - Conversion 잔액은 −730 USD + 1,000,000 KRW다. 원화로 평가하면 −95,000원, 즉 대변 95,000원이다.
  - 따라서 이익이 95,000원이다.

### 4.3 시세

| 종류 | 저장 위치 | 싱크 |
|---|---|---|
| 사용자가 직접 입력한 시세 | op(`set_price`) → `price` 테이블 | ○ |
| 외부에서 받아온 시세 | `market_price` 로컬 캐시 | ✕ (각 기기가 직접 받는다) |

**환율.** ECB 기준환율을 쓴다.
- 무료이고 API 키가 필요 없다.
- KRW를 포함하고, 1999년부터의 이력이 있다.
- 모든 통화를 한 번에 받으므로, 어떤 통화를 보유했는지 외부에 드러나지 않는다.

**주가.** phase 1은 수동 입력만 지원하고, 이후 `PriceProvider` 플러그인으로 넓힌다. 종목별로 조회하면 포트폴리오가 제공자에게 노출된다는 점을 설정 화면에 명시한다.

**암호화폐.** 이후 단계에서 다룬다.

**갱신.** 앱을 실행할 때, 또는 하루에 한 번 받는다. 이력은 해당 커모디티를 보유하기 시작한 날부터 채운다.

```swift
public protocol PriceProvider: Sendable {
    var id: String { get }
    func quotes(for pairs: [PricePair], in range: ClosedRange<LocalDate>) async throws -> [PriceQuote]
}
```

### 4.4 평가

```
value(holdings, target, asOf):
  커모디티 c마다:
    c == target                → 그대로
    아니면 c → … → target 경로 탐색 (양방향, 깊이 ≤ 3. 예: AAPL → USD → EUR → KRW)
      각 구간 환율 = asOf 이전 가장 최근 시세. 수동 입력이 캐시보다 우선
    경로가 없으면              → unvalued로 따로 보고. 절대 0으로 환산하지 않는다
  결과: 합계, unvalued 목록, 사용한 시세 중 가장 오래된 기준일
```

- 계산은 `Decimal`로 하고, 반올림은 표시할 때만 한다.
- UI에는 시세의 **기준일**을 함께 표시한다. 시세가 없는 금액은 원래 통화로 보여주고 "시세 없음"을 붙인다.
- **평가 기준일(제안).**
  - 잔액과 순자산은 조회 기준일의 시세로 평가한다.
  - 기간 수입·지출 보고서는 각 포스팅의 거래일 시세로 평가한다.
  - 거래 하나 안에서는 통화별 합이 0이므로, 거래 단위로 같은 날짜의 시세를 쓰면 보고서도 균형이 맞는다.
- **순자산 시계열.** 일별·통화별 누적 잔액에 시세 시계열을 곱한다. 시세가 없는 날은 직전 값으로 채운다.

### 4.5 범위 밖 (phase 3)

로트별 취득원가(양도세 계산)는 다루지 않는다. 총 평가손익은 4.2의 방식으로 이미 나온다.

## 5. 저장소 (SQLite)

### 5.1 op 테이블: 진실의 원천

```sql
CREATE TABLE op (
  id           TEXT PRIMARY KEY,   -- UUID (body에도 포함)
  status       TEXT NOT NULL,      -- main | pending   (로컬 전용 메타데이터)
  seq          INTEGER UNIQUE,     -- main 순번. pending이면 NULL
  local_order  INTEGER,            -- pending의 작성 순서
  body         BLOB NOT NULL,      -- 작성 기기가 만든 바이트 그대로. 재인코딩 금지
  resolution   BLOB,               -- main만: 병합 해결 결과 (§6.3). 해결이 필요 없었으면 NULL
  kind         TEXT NOT NULL,      -- body에서 추출 (인덱스용)
  target       TEXT NOT NULL,      -- body에서 추출: 대상 엔티티 ID (편집 이력, 3-way merge용)
  version      INTEGER NOT NULL,   -- body에서 추출
  prev_hash    BLOB,               -- main만
  state_digest BLOB,               -- main만: 이 op까지 적용한 상태의 다이제스트
  hash         BLOB                -- main만
);
CREATE INDEX op_by_target ON op(target, seq);
```

### 5.2 머티리얼라이즈드 테이블: 로컬, 언제든 재생성 가능

- 모든 행에 `rev` 열이 있다. `rev`는 그 행을 마지막으로 바꾼 op의 id다. op id는 rebase를 거쳐도 변하지 않으므로 동시 편집을 감지하는 기준이 된다.
- op는 순서대로만 적용되고 구조적 불변식이 항상 유지된다. 그래서 싱크 테이블과 달리 이 테이블들에는 FK를 걸 수 있다.

```sql
CREATE TABLE commodity (
  id TEXT PRIMARY KEY, code TEXT NOT NULL, kind TEXT NOT NULL, scale INTEGER NOT NULL,
  name TEXT, quote_id TEXT REFERENCES commodity(id), feed TEXT,
  archived INTEGER NOT NULL DEFAULT 0, rev TEXT NOT NULL
);

CREATE TABLE account (
  id TEXT PRIMARY KEY, parent_id TEXT REFERENCES account(id),
  name TEXT NOT NULL, type TEXT NOT NULL, role TEXT,
  opened_on TEXT NOT NULL, closed_on TEXT,
  archived INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0,
  merged_into TEXT REFERENCES account(id),
  sort_order INTEGER NOT NULL DEFAULT 0, note TEXT, rev TEXT NOT NULL
);

CREATE TABLE entry (
  id TEXT PRIMARY KEY, date TEXT NOT NULL, created_at TEXT NOT NULL,
  payee TEXT, memo TEXT, rev TEXT NOT NULL
);
CREATE INDEX entry_by_date ON entry(date, created_at, id);

-- account_id는 작성된 그대로이고, resolved_account_id는 merged_into를 따라간 결과다.
-- 잔액과 레지스터는 resolved_account_id를 쓴다. 계정 병합은 resolved 열만 바꾸므로
-- 거래 내용(과 rev, 다이제스트)은 그대로다.
CREATE TABLE posting (
  entry_id            TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
  idx                 INTEGER NOT NULL,
  date                TEXT NOT NULL,                 -- entry.date 복사 (인덱스용)
  account_id          TEXT NOT NULL REFERENCES account(id),
  resolved_account_id TEXT NOT NULL REFERENCES account(id),
  commodity_id        TEXT NOT NULL REFERENCES commodity(id),
  amount              INTEGER NOT NULL,
  PRIMARY KEY (entry_id, idx)
) WITHOUT ROWID;
CREATE INDEX posting_by_account ON posting(resolved_account_id, date, commodity_id, amount);

CREATE TABLE price (
  id TEXT PRIMARY KEY, base_id TEXT NOT NULL, quote_id TEXT NOT NULL,
  date TEXT NOT NULL, rate TEXT NOT NULL, rev TEXT NOT NULL
);

CREATE TABLE balance_assertion (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL, commodity_id TEXT NOT NULL,
  date TEXT NOT NULL, amount INTEGER NOT NULL, rev TEXT NOT NULL
);

CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev TEXT NOT NULL);

CREATE TABLE conflict_dismissal (op_id TEXT PRIMARY KEY);   -- dismiss_conflict op의 결과
```

### 5.3 로컬 보조 테이블

```sql
-- op 적용 시 바뀐 행의 이전 이미지. pending 되돌리기, 실행 취소, 변경 이벤트에 쓴다
CREATE TABLE op_undo (op_id TEXT NOT NULL, step INTEGER NOT NULL, tbl TEXT NOT NULL,
                      row_key TEXT NOT NULL, before BLOB,   -- NULL = 새로 생긴 행
                      PRIMARY KEY (op_id, step));

-- 외부 시세 캐시
CREATE TABLE market_price (
  base_id TEXT NOT NULL, quote_id TEXT NOT NULL, date TEXT NOT NULL,
  rate TEXT NOT NULL, provider TEXT NOT NULL, fetched_at TEXT NOT NULL,
  PRIMARY KEY (base_id, quote_id, date, provider)
) WITHOUT ROWID;

-- device_id, hlc, main_head_seq, main_head_hash, state_digest, …
CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
```

### 5.4 마이그레이션

- 신중하게 마이그레이션해야 하는 것은 op 테이블과 op body 포맷뿐이다.
- 머티리얼라이즈드 테이블의 스키마가 바뀌면 테이블을 지우고 로그 전체를 재생해 다시 만든다. 이 테이블들에는 마이그레이션 코드를 쓰지 않는다.
- 스키마가 달라졌는지는 `PRAGMA user_version`으로 판단한다.

### 5.5 쿼리와 성능

- **규모 가정.** 하루 20건씩 10년이면 거래 약 7.3만 건, 포스팅 약 18만 행이다. 성능 목표는 이보다 넉넉하게 10만 건으로 잡는다(§8.2).
- **계정 잔액.** `posting_by_account` 커버링 인덱스에서 `SUM`으로 구한다. ms 단위다.
- **메모리에 두는 것.** 계정 트리, 커모디티, 열린 목록의 정렬 키 배열, 열린 레지스터의 누적합을 둔다(§8.3).
- **월별 잔액 스냅샷 테이블.** 측정해서 느릴 때만 추가한다.
- **전체 재생.** 10만 op 기준 수 초 안을 목표로 하고, 측정으로 확인한다.

### 5.6 파일 위치 (제안)

- phase 1부터 DB를 App Group 컨테이너에 둔다.
- 그러면 phase 3에서 CLI를 앱 번들에 넣을 때 파일을 옮기지 않아도 된다.
- CLI의 서명과 엔타이틀먼트 세부는 phase 3에서 검증한다.

## 6. op

### 6.1 봉투

```json
{"v":1,"id":"…","device":"…","at":"1759032753123-0003","kind":"post_entry","payload":{…}}
```

- **인코딩은 한 번만 한다.** 인코딩은 작성한 기기만 한다. 저장과 전송은 바이트 그대로 한다.
- **다시 인코딩하지 않는다.** 디코딩할 때 모르는 필드는 무시하되, 바이트는 보존하고 다시 인코딩하지 않는다.
- **`v`는 op 포맷 버전이다.** main에 모르는 `v`가 있으면 그 지점부터 적용할 수 없으므로 앱 업데이트를 요구한다(§7.4).
- **`at`은 HLC(hybrid logical clock)다.** 물리 시각(ms)에 카운터를 붙인 값이다.
  - 기기는 main을 받을 때마다 자기 HLC를 본 값 중 최댓값 이상으로 올린다.
  - 그래서 다른 기기의 변경을 본 뒤 한 편집은, 시계가 틀려도 항상 더 늦은 시각을 갖는다.
  - 병합 정책의 "나중 것"은 이 값으로 판단하고, 동률이면 device id로 가른다.
  - main의 순서를 정하는 데는 쓰지 않는다.
  - `post_entry`의 `at`은 `entry.created_at`이 된다.

### 6.2 종류와 작성 시 검증

op 종류는 런타임 커맨드와 일대일로 대응한다. **작성 시 검증**은 로컬에서 op를 만들 때 적용하는 규칙이다. 병합할 때는 이 규칙으로 거부하지 않고, §6.3의 정책으로 해결한다.

`base_rev`가 있는 op는 작성할 때 현재 `rev`와 같아야 한다. 다르면 편집하던 사본이 낡았다는 뜻이다(예: 두 창에서 같은 거래를 편집). 이 경우 작성을 거부하고, UI가 새로 읽어 다시 편집하게 한다. 따라서 3-way merge는 rebase할 때만 일어난다.

| kind | payload | 작성 시 검증 |
|---|---|---|
| `create_commodity` | id, code, kind, scale, name, quote, feed | 같은 id가 없어야 한다(결정적 ID이고 내용이 같으면 no-op) |
| `update_commodity` | id, base_rev, name, quote, feed | code와 scale은 바꿀 수 없다 |
| `archive_commodity` | id, base_rev | |
| `open_account` | id, parent, name, type, opened_on, role | 부모가 존재하고 type이 같아야 한다. 형제 중에 같은 이름이 없어야 한다 |
| `update_account` | id, base_rev, name, parent, sort_order, note | type은 바꿀 수 없다. 순환이 없어야 하고, 이름이 겹치지 않아야 한다 |
| `close_account` | id, base_rev, date | 해지일 이후 포스팅이 없어야 한다 |
| `reopen_account` | id, base_rev | |
| `archive_account` | id, base_rev | |
| `merge_accounts` | from, into | type이 같아야 한다. from ≠ into이고, into가 from의 하위 계정이 아니어야 한다 |
| `delete_account` | id, base_rev | 포스팅, 하위 계정, 잔액 단언이 없어야 한다 |
| `post_entry` | id, date, payee, memo, postings | 포스팅이 2개 이상이고 통화별 합이 0이어야 한다. 계정은 존재하고, 보관되지 않았고, 개설~해지 기간 안이어야 한다 |
| `amend_entry` | id, base_rev, date, payee, memo, postings | `post_entry`와 같다. 내용 전체를 교체한다 |
| `void_entry` | id, base_rev | 장부에서는 사라지지만 로그에는 남는다 |
| `set_price` | id, base, quote, date, rate | 커모디티가 존재해야 하고 rate > 0이어야 한다 |
| `remove_price` | id, base_rev | |
| `assert_balance` | id, account, commodity, date, amount | 계정과 커모디티가 존재해야 한다 |
| `remove_assertion` | id, base_rev | |
| `set_setting` | key, value | 키별로 값을 검사한다 |
| `dismiss_conflict` | op_id | 충돌 로그에서 확인한 항목을 숨긴다. 모든 기기에 전파된다 |

**어떤 경우에도 성립하는 구조적 불변식**
- **거래별 통화 균형.** op 하나 안에서 검사하므로 병합으로 깨질 수 없다.
- **참조 해석 가능.** 계정은 실제로 지우지 않고 톰스톤(`deleted`)으로 표시한다. 다른 계정에 병합된 계정은 `merged_into`로 리다이렉트한다. 모든 참조는 해석하기 전에 `merged_into`를 따라간다.
- **계정 트리 비순환.**
- **불변 필드.** type과 scale은 바꿀 수 없다.

### 6.3 병합 정책 (제안)

rebase 중에 pending op가 새 main 상태와 부딪히면 아래 기본 정책으로 해결한다. 해결 결과는 op의 `resolution`에 기록되어 main에 들어간다.

| 상황 | 기본 해결 | 충돌 로그 |
|---|---|---|
| 같은 거래를 동시에 수정 | **필드 그룹 단위 3-way merge.** 그룹은 {date}, {payee}, {memo}, {postings}다. 한쪽만 바꾼 그룹은 그 변경을 반영한다. 양쪽이 모두 바꾼 그룹은 `at`이 늦은 쪽을 택한다. **postings는 항상 통째로 고르고, 포스팅 단위로 섞지 않는다.** | ○ (postings가 밀린 경우 강조) |
| 수정 ↔ 무효화 | `at`이 늦은 쪽을 택한다. 수정이 늦으면 거래가 되살아난다 | ○ |
| 무효화 ↔ 무효화 | no-op | ✕ |
| 계정·커모디티 속성을 동시에 수정 | 필드 단위 3-way merge. 양쪽이 모두 바꾼 필드는 `at`이 늦은 쪽을 택한다 | ○ |
| 해지된 계정에 거래 | 거래를 반영한다. 기간 위반은 진단으로 보여준다 | 진단 |
| 보관된 계정에 거래 | 거래를 반영하고 계정 보관을 해제한다 | ○ |
| 삭제된 계정에 거래 | 거래를 반영하고 계정을 되살린다 | ○ |
| 삭제하려던 계정이 그사이 사용됨 | 삭제 대신 보관으로 처리한다 | ○ |
| 병합된 계정에 거래 | `merged_into`로 리다이렉트한다 | ✕ |
| 계정 이동이 순환을 만듦 | 그 이동은 no-op으로 처리한다 | ○ |
| 형제 계정 이름 중복 | 둘 다 유지하고, 나중 것에 " (2)"를 붙인다 | ○ (병합 액션 제공) |
| 같은 (base, quote, date)의 수동 시세 | 둘 다 저장한다. 조회할 때는 `at`이 늦은 쪽을 쓴다 | ✕ |
| 설정 동시 변경 | `at`이 늦은 쪽을 택한다 | ✕ |

**3-way merge의 base.** op의 `base_rev`가 base 시점을 가리킨다.
- 로그에서 대상 엔티티의 op를 `base_rev`까지 접어(fold) base 내용을 복원한다(`op_by_target` 인덱스 사용).
- "상대가 바꾼 필드"와 그 필드의 `at`은 base 이후 같은 대상에 적용된 main op들에서 구한다.

**해결 결과를 기록하는 이유(원칙 4).**
- 재생은 정책을 다시 계산하지 않는다. `resolution`이 있으면 그 안의 유효 payload를, 없으면 body의 payload를 적용한다.
- 그래서 앱 업데이트로 정책 코드가 바뀌어도 과거의 재생 결과는 변하지 않는다.

```json
{"rule":"field_merge","effective":{…적용된 payload…},"lost":["postings"],"against":["<op id>"]}
```

### 6.4 진단

구조적으로는 문제가 없지만 사용자가 알아야 하는 상태다. 입력을 막지 않는다.

```swift
public enum Diagnostic: Sendable, Hashable {
    case balanceAssertionFailed(BalanceAssertion.ID, expected: Amount, actual: Amount)
    case postingOutsideOpenPeriod(Entry.ID, Account.ID)
    case closedAccountHasBalance(Account.ID, Holdings)
    case missingPrice(Commodity.ID, target: Commodity.ID, asOf: LocalDate)
    case stalePrice(Commodity.ID, target: Commodity.ID, lastDate: LocalDate)
}
```

## 7. 싱크

### 7.1 모델

- **main.** 원격에 있는 하나의 선형 op 로그다. 순서는 조건부 append(CAS)로 정한다.
- **로컬.** main의 사본 위에 pending op를 덧씌운 상태다. 화면에 보이는 것은 main과 해결된 pending을 합친 결과다.
- **로컬 전용 모드(phase 1).** 기기 자신이 순서를 정한다. 커맨드는 곧바로 seq, state_digest, hash를 받아 main에 들어간다.
- **phase 2에서 싱크를 켤 때.** 기존 로컬 main op를 pending으로 되돌린 뒤 원격 main 위로 rebase한다. 원격이 비어 있으면 그대로 올린다.

### 7.2 해시 체인과 상태 다이제스트

```
hash(n)         = SHA-256( hash(n−1) ‖ state_digest(n) ‖ enc(body(n)) ‖ enc(resolution(n)?) )   hash(0) = 0x00 × 32
state_digest(n) = n번째 op까지 적용한 상태의 다이제스트
```

`body`와 `resolution`은 가변 길이라서 아래의 `enc`(길이 접두사)로 감싼다. 그래야 두 필드의 경계가 모호해지지 않는다.

- **해시 체인.** 전송·저장 중의 손상, 변조, 이력 분기를 탐지한다.
  - 해시는 **저장된 바이트**에 대해 계산한다. 다시 인코딩한 바이트를 쓰지 않으므로 정규 직렬화가 필요 없다.
- **상태 다이제스트.** 같은 op를 재생했는데 기기마다 다른 상태가 나오는 경우를 탐지한다. 앱 버전 간 해석 차이나 버그가 원인이 될 수 있다.
  - 직렬화 포맷이 아니라, 직접 정의한 함수로 계산한다.

```
enc(UUID)      = 16바이트
enc(LocalDate) = "YYYY-MM-DD" 10바이트
enc(Int64)     = 8바이트 big-endian
enc(String)    = UInt32 big-endian 길이 ‖ UTF-8(NFC)
enc(Bytes)     = UInt32 big-endian 길이 ‖ 바이트
enc(x?)        = 0x00  |  0x01 ‖ enc(x)
enc(Bool)      = 0x00  |  0x01

record_digest(entry) = SHA-256( enc("cowry.entry.v1")
                              ‖ enc(id) ‖ enc(date) ‖ enc(created_at) ‖ enc(payee?) ‖ enc(memo?) ‖ enc(rev)
                              ‖ enc(Int64(postings.count))
                              ‖ 포스팅마다 enc(account) ‖ enc(commodity) ‖ enc(amount) )
… 다른 레코드 종류도 같은 방식이며, 태그로 도메인을 분리한다

state_digest = Σ record_digest(r)  mod 2²⁵⁶      r = 모든 도메인 레코드 (캐시 제외)
```

- **증분 계산.** op를 적용할 때 `− 이전 레코드 다이제스트 + 새 레코드 다이제스트`만 하면 된다. O(1)이다.
  - 합산 방식은 의도적인 조작에는 약하다. 조작은 해시 체인이 막는다.
- **고정.** 다이제스트 함수는 테스트 벡터로 고정한다. 바꿔야 할 때는 op 버전 경계에서 새 함수를 추가한다.

### 7.3 전송 계층

```swift
public protocol LogRemote: Sendable {
    /// seq > after 인 op를 순서대로 흘려보낸다. 새 op가 올라오면 계속 보낸다
    func ops(after seq: Int64) -> AsyncThrowingStream<[RemoteOp], Error>

    /// 원격 head가 expectedHead일 때만 추가한다
    func append(_ ops: [RemoteOp], expectedHead: Int64) async throws -> AppendResult
}

public struct RemoteOp: Sendable {
    public let seq: Int64
    public let body: Data
    public let resolution: Data?
    public let prevHash: Data
    public let stateDigest: Data
    public let hash: Data
}

public enum AppendResult: Sendable { case appended, headMoved }
```

| 구현 | 용도 |
|---|---|
| `InMemoryRemote` | 테스트. 가짜 기기 여러 대를 한 프로세스 안에서 시뮬레이션한다 |
| `CloudKitRemote` | phase 2 (§7.6) |

### 7.4 알고리즘

```
1. fetch    원격에서 seq > 로컬 head인 op를 받는다. 빈 번호 없이 이어지는 데까지만 쓴다
            prev_hash와 hash를 검증한다. HLC를 올린다
2. 되돌리기 pending op를 역순으로 되돌린다 (op_undo)
3. 적용     main op를 순서대로 적용한다. resolution이 있으면 그것을 쓴다. op마다 state_digest를 비교한다
4. rebase   pending op를 작성 순서대로 새 상태 위에 적용한다
              부딪히지 않음 → 그대로 적용
              부딪힘        → §6.3 정책으로 해결하고 resolution을 만든다
            어떤 op도 거부하지 않는다
5. push     pending op에 seq = head+1…, resolution, state_digest, hash를 붙여 append(expectedHead: head)
              headMoved이면 1로 돌아간다
```

| 상황 | 처리 |
|---|---|
| 해시 불일치 | 싱크를 중단하고 원격 손상을 보고한다 |
| 다이제스트 불일치 | 로컬을 처음부터 재생해 다시 확인한다. 그래도 다르면 재생 발산(버그)으로 보고하고 싱크를 중단한다 |
| 모르는 op 버전 | main 적용을 멈추고 앱 업데이트를 요구한다. 로컬 입력은 pending으로 계속 쌓인다 |
| `headMoved` | fetch부터 반복한다 |
| 오프라인 | pending이 쌓이고, 화면은 계속 유효하다 |

### 7.5 충돌 로그

- **무엇이 보이나.** `resolution`이 있는 main op 가운데 충돌 로그 대상(§6.3)만 표시한다.
  - 해결 결과는 main에 있으므로 모든 기기가 같은 로그를 본다.
  - 밀린 내용은 로그에 남아 있으므로 언제든 복원할 수 있다.
- **각 항목에 보이는 것.** 어떤 규칙이 적용됐는지, 무엇이 밀렸는지, 양쪽 버전.
- **사용자 액션**
  - **이 버전으로 되돌리기.** 밀린 쪽 내용으로 새 `amend_entry`를 만든다. 평범한 op다.
  - **병합하기.** 이름 중복일 때 `merge_accounts`를 만든다.
  - **확인.** `dismiss_conflict`를 만든다.
- **강조.** postings(금액)가 밀린 항목은 사이드바 배지로 강조한다. 메모나 payee가 밀린 항목은 조용히 기록만 한다.
- **거부는 없다.** 어떤 op도 해결을 기다리며 멈춰 있지 않는다.

### 7.6 CloudKit 매핑 (phase 2)

- **존.** 장부 하나에 커스텀 존 하나를 쓴다.
- **레코드.** 레코드 타입은 `Op`, 레코드 이름은 `op-<seq, 12자리 0 채움>`이다.
  - 필드: `body`와 `resolution`(둘 다 `encryptedValues`), `prev_hash`, `state_digest`, `hash`.
- **CAS.** 같은 이름의 레코드가 이미 있으면 서버가 저장을 거부한다. 이를 `headMoved`로 해석한다. 여러 op는 존 단위 원자적 저장으로 한 번에 올린다.
- **먼저 검증할 것.** CKSyncEngine이 이 의미론을 표현할 수 있는지 작은 프로토타입으로 확인한다.
  - 안 되면 `CKModifyRecordsOperation`과 `CKFetchRecordZoneChangesOperation`으로 내려간다.
  - 필요한 동작이 append와 fetch 두 가지뿐이라 비용이 작다.
- **받아들이는 단점**
  - iCloud 로그아웃이나 용량 초과 시 싱크가 멈춘다. UI에 싱크 상태를 표시한다.
  - 프로덕션 스키마에서는 필드를 지울 수 없다. 대신 op 레코드의 필드는 거의 바뀌지 않고, 도메인 변화는 body의 `v`로 흡수한다.

## 8. UI (macOS, AppKit)

### 8.1 구성

- `NSSplitViewController`로 세 영역을 나눈다.
  - **사이드바.** 계정 트리(`NSOutlineView`)를 보여준다. primary currency 기준 잔액과 원래 통화 잔액을 함께 표시한다. 진단과 충돌 로그 배지도 여기에 둔다.
  - **목록.** 일기장 또는 계정 레지스터를 view-based `NSTableView`로 보여준다.
  - **인스펙터.** 거래를 편집한다.
    - 작성 시 검증 오류는 해당 필드 옆에 바로 표시한다.
    - 다중통화를 입력할 수 있고, 암시된 환율을 표시한다.
    - 편집 이력(`history(of:)`)을 볼 수 있다.
- **그 밖의 화면.** 보고서(재무상태표, 기간 손익, 순자산 추이), 진단, 충돌 로그, 설정(primary currency, 커모디티, 시세 소스).
- **SwiftUI 혼용.** 설정처럼 정적인 화면은 필요하면 `NSHostingController`로 SwiftUI를 섞을 수 있다. 목록과 편집은 AppKit으로 한다.

### 8.2 성능 목표 (제안)

거래 10만 건 기준이다.
- **스크롤.** 끊김이 없어야 한다.
- **필터·검색.** 입력한 뒤 100ms 안에 결과를 보여준다.
- **편집 반영.** 한 프레임 안에 반영하고, 선택과 스크롤 위치를 유지한다.

측정용으로 합성 데이터 생성기를 phase 1에 포함한다.

### 8.3 가상화된 목록

```
LedgerSnapshot.journal(filter)  →  JournalIndex: 정렬 키 배열 [(date, created_at, id)]
                                   10만 건 × 약 40바이트 ≈ 4MB
numberOfRows                    =  index.count
보이는 행 ± 여유분               →  snapshot.entries(ids) 배치 동기 읽기 → 컨트롤러 캐시
LedgerChange                    →  바뀐 ID를 정렬 키로 이진 탐색해 인덱스 diff
                                   insertRows / removeRows / reloadData(forRowIndexes:)
```

- **전체 리로드는 하지 않는다.** `NSTableViewDiffableDataSource`도 쓰지 않는다. 변경마다 10만 개 식별자 전체를 비교하게 되기 때문이다. 대신 변경 이벤트가 알려주는 ID만으로 직접 갱신한다.
- **필터와 검색.** SQL로 새 정렬 키 배열을 만든다. 변경 이벤트가 오면 바뀐 ID만 `WHERE id IN (…) AND <필터>`로 다시 판정한다.
- **검색 방식.** 이 규모에서는 `LIKE` 전체 스캔으로 충분하고, 검색어도 NFC로 정규화한다. FTS5 trigram 토크나이저는 3글자 미만을 찾지 못한다. 그래서 "커피" 같은 두 글자 한국어 검색에 맞지 않아 쓰지 않는다.
- **레지스터 누적 잔액.** 계정별로 (정렬 키, 금액) 배열과 누적합을 메모리에 둔다. 과거 날짜에 거래가 끼어들면 그 지점 이후만 다시 계산한다.
- **행 높이.** 고정한다(`usesAutomaticRowHeights = false`).

## 9. 테스트 전략

- **LedgerCore 단위 테스트.** 작성 시 검증, 환전 포스팅 생성, 금액 연산, 값 정규화(NFC 등), 병합 정책을 사례별로 검증한다.
- **다이제스트 테스트 벡터.** 고정된 입력과 기대 해시를 둔다. 명세가 바뀌면 즉시 실패한다.
- **속성 테스트.** 무작위 op 시퀀스로 다음을 확인한다.
  - 모든 시점에서 구조적 불변식이 성립한다.
  - 처음부터 재생한 다이제스트와 증분 다이제스트가 같다.
  - pending을 적용했다가 되돌리면 main 다이제스트로 돌아온다.
  - resolution을 기록한 main을 재생하면, 해결 당시와 같은 다이제스트가 나온다.
- **다기기 시뮬레이션.** `InMemoryRemote`와 가짜 기기 N대로 돌린다. 무작위로 온라인·오프라인을 오가며 op를 뿌린다.
  - main은 항상 구조적 불변식을 만족한다.
  - 모든 op가 결국 main에 들어간다. 잃어버리는 op가 없다.
  - 모두 조용해지면 모든 기기의 다이제스트가 같다.
- **목록 성능 벤치마크.** 합성 10만 건으로 필터, 검색, 변경 반영 시간을 측정한다.

UI 없이도 런타임 전체를 테스트할 수 있다.

## 10. 단계

**Phase 1 — 로컬 전용 macOS 앱**
- `LedgerCore`: 타입, op, 작성 시 검증, 병합 정책, 환전 포스팅, 다이제스트.
- `Ledger`
  - op 로그, 머티리얼라이즈, op_undo.
  - 스냅샷 읽기와 변경 스트림.
  - 평가, 진단, 로컬 순서 결정.
  - 싱크 엔진과 `InMemoryRemote`(테스트용).
- `Pricing`: ECB, 수동 시세.
- AppKit 앱(§8), 합성 데이터 생성기.

**Phase 2 — 싱크와 iOS**
- CKSyncEngine CAS 프로토타입, 그다음 `CloudKitSync`.
- iOS 앱(UIKit). 목록 가상화 구조(§8.3)는 `UICollectionView`로 그대로 옮긴다.
- 충돌 로그 UI, 싱크 상태 UI.
- 기존 로컬 장부를 싱크에 합류시키는 흐름(§7.1).

**Phase 3 — 확장**
- **CLI.**
  - 앱 번들에 포함하고 App Group 컨테이너를 쓴다.
  - 외부 변경은 `PRAGMA data_version`으로 감지한다.
  - 스키마 버전이 더 높은 DB는 열지 않는다.
- **자산 관리.** 로트별 취득원가, 주가 제공자 플러그인.
- **Merkle 체크포인트.** 연/월/일 트리 스냅샷이다. 새 기기 부트스트랩, 과거 시점 열람, 노드 해시를 키로 한 합계 캐시에 쓴다.
- **로그 압축.** 오래된 op를 묶어 아카이브한다.
- **내보내기와 가져오기.** beancount 내보내기, 외부 가져오기 도구와의 연동.

## 11. 기각한 대안

| 대안 | 기각 이유 |
|---|---|
| Rust 코어 + C FFI | 목표가 Apple 전용이라, FFI 경계·다중 타깃 빌드·언어 간 디버깅 비용만 남는다 |
| CLI 서버(데몬) + 인메모리 날짜 인덱스 | 진실의 원천이 둘이 된다. iOS에서는 불가능하다. 이 규모에서는 SQLite 인덱스로 충분하다 |
| SwiftData / Core Data | 집계 쿼리가 약하다. 모델과 병합을 통제할 수 없다 |
| SwiftUI 목록 | 대량 목록에서 성능 문제가 있다. 전체 장부 탐색이 핵심 경험이다 |
| 상태 복제 + LWW (SQLiteData 등) | 레코드 사이의 불변식이 병합 후 깨진다. 이력이 없다. 해결 결과를 기록할 곳이 없다 |
| 병합 충돌 시 사용자 해결 필수 (op 거부) | 사용자가 처리하기 전까지 입력이 장부에 반영되지 않는다. 대부분의 충돌은 자연스러운 해결책이 있다 |
| git식 기기별 브랜치 + merge | 충돌 없이 merge됐다고 유효한 것은 아니다. merge commit끼리 발산한다 |
| Merkle 상태 트리를 싱크의 뼈대로 | 선형 로그와 이점이 겹친다. 쓰기 증폭이 있고 CKSyncEngine과 맞지 않는다. 체크포인트로만 쓴다 |
| beancount식 `@가격` 균형 | 반올림 허용오차 규칙이 필요하다 |
| SQLite 파일을 iCloud Drive에 두기 | WAL 파일이 따로 동기화되면서 DB가 손상된다 |
| iCloud Drive 파일 로그 | CAS가 없어서 선형 로그가 성립하지 않는다 |
| 자체 서버 | 운영·인증 부담이 있고, 남의 금융 데이터를 보관하는 책임을 져야 한다 |

## 12. 열린 질문

1. **해외결제 기본 입력 방식.** 원화만 입력할지, 원래 통화와 청구 원화를 함께 입력할지 정해야 한다. 모델은 둘 다 지원하므로 UI 기본값의 문제다.
2. **최소 OS 버전.** 잠정적으로 macOS 15 / iOS 18로 잡았다. CKSyncEngine의 하한은 macOS 14 / iOS 17이다.
3. **해지 계정 잔액.** 잔액이 0이 아닌 해지 계정을 작성 시 검증으로 막을지, 진단으로 둘지 정해야 한다. 현재 안은 진단이다.
4. **기간 손익 평가 기준.** 거래일 시세(현재 안)와 조회 기준일 시세 중 무엇을 쓸지 정해야 한다.
5. **이름 중복 계정의 기본 처리.** " (2)"를 붙여 둘 다 둘지(현재 안), 자동으로 병합할지 정해야 한다.
6. **주가 제공자.** 어떤 제공자를 먼저 붙일지 정해야 한다(phase 3).
