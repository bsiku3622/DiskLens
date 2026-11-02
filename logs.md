# DiskLens logs

## 2026-11-02 — `/private/var` 경로를 못 찾던 MCP 조회 수정 (0.5.1)

- 변경 파일: `Core/Annotations.swift`
- 요약: `/` 스캔 결과에서 `list`로 `/private/var/...`를 조회하면 17GB짜리 폴더도 "min size보다 작다"는 오류가 났습니다. `normalize`가 경로를 트리와 같은 모양으로 맞추도록 고쳤습니다.

`standardizedFileURL`은 `/private/var`에서 `/private`를 떼어 `/var`로 만듭니다. 그런데 `/`를 스캔한 트리는 `/private/var`로만 내려가므로 찾지 못하고, 찾지 못한 경로는 모두 min size 오류로 안내됩니다. 메시지가 틀려서 원인을 알아보기 어려웠습니다. 트리 쪽을 `/var`로 맞추지 않고 입력 쪽을 `/private`로 맞췄습니다. 실제 경로가 `/private` 쪽이고, 그쪽이 고칠 곳이 `normalize` 한 곳뿐이기 때문입니다. `/var`, `/tmp`, `/etc`만 되돌리고, `/variable` 같은 이름은 건드리지 않습니다.

같은 함수를 쓰는 곳도 따라 바뀝니다. `scan /var`의 root는 이제 `/private/var`입니다. `annotate`도 `/private/...`로 저장되어, 코드상 `/` 스캔 차트의 노드 경로와 일치합니다(화면으로 확인하지는 않았습니다). 이미 저장된 `/var/...` 표시는 다시 쓸 때까지 그대로입니다.

시험 타깃이 없어서 빌드한 앱을 `--mcp`로 띄워 `/`를 실제로 스캔한 뒤 경로 표기별로 15개를 확인했습니다: `~/Bufs/Claude Files/2026-11-02/disklens-path-fix/mcp-test.py`. 이때 `/` 스캔은 680초로 평소보다 오래 걸렸는데, 같은 시간에 Fusion 업데이트와 다른 세션들이 돌고 있었고 원인을 따로 재지는 않았습니다.

찾지 못한 경로를 전부 min size 탓으로 돌리는 오류 문구는 그대로입니다. 없는 경로 `/variable-does-not-exist`에도 같은 문구가 나옵니다.

## 2026-11-02 — clone을 한 번만 세도록 수정, FAT 용량 0 수정 (0.5.0)

- 변경 파일: `Core/Scanner.swift`, `Design/L10n.swift`, `Core/VolumeMap.swift`, `Headless/MCPServer.swift`, `README.md`
- 요약: 전체 합계가 529~550GB에서 229GB로 줄어 실제 사용량 242GB 바로 아래로 왔습니다. 스캔 시간은 그대로입니다(같은 조건에서 64초 대 67초). FAT 볼륨에서 용량이 0으로 나오던 10-28 회귀도 고쳤습니다.

하드링크와 clone을 하나로 묶었습니다. APFS에서는 하드링크도 clone ID가 같으므로, "같은 데이터 스트림"을 키로 삼으면 inode 집합을 따로 둘 필요가 없습니다. clone ID가 없는 볼륨(exFAT, HFS+, SMB)에서만 inode를 키로 씁니다. 시스템 볼륨의 clone ID는 `0x0FFF…` 대역이라 Data 볼륨과 겹치지 않습니다. 파일 350만 개를 표에 넣지 않으려고 `ATTR_CMNEXT_CLONE_REFCNT`가 2 이상이거나 링크가 2개 이상인 것만 추적합니다. 시스템 볼륨은 참조 횟수가 0으로 오지만, 전부 추적한 프로토타입과 합계가 일치했습니다.

⚠️ **먼저 도착한 쪽에 크기를 매기면 안 됩니다.** 병렬 탐색이라 도착 순서가 매번 달라서, 어떤 날은 Chrome.app이 0으로, 어떤 날은 임시 복사본이 2.3GB로 나옵니다. 그래서 더 나은 이름이 나타나면 크기를 옮기고, 규칙(임시 폴더·캐시·휴지통 밖 → 짧은 경로 → 가나다순)으로 정해서 같은 디스크면 결과가 같습니다. 옮길 때 트리 잠금 안에서 조상 전체를 빼고 더합니다. 대상은 공유 데이터뿐이라 비용이 작습니다.

남은 한계: 복사 후 수정한 clone은 clone ID가 새로 생겨 전체 크기로 잡힙니다(1MB만 고친 5MB clone이 5MB로 나옴). `ATTR_CMNEXT_PRIVATESIZE`로 더 정확히 할 수 있지만 파일마다 비용이 얼마나 드는지 재지 않아 이번에는 넣지 않았습니다. 크기가 매겨진 사본만 지우면 다른 사본이 데이터를 잡고 있어서 공간이 거의 돌아오지 않는데, 차트는 다음 스캔 전까지 줄어든 것처럼 보입니다.

⚠️ **새 스캔 엔진은 APFS 밖에서도 시험해야 합니다.** 10-28에 APFS로만 시험해서 FAT 회귀를 놓쳤습니다. FAT는 일괄 조회에서 `ATTR_FILE_ALLOCSIZE`를 주지 않으므로(반환 비트로 확인) 그 파일만 `lstat`으로 읽습니다. `hdiutil create -fs ExFAT|HFS+|MS-DOS`로 만든 이미지와 SMB 마운트로 확인할 수 있습니다. 측정·시험 도구는 `~/Bufs/Claude Files/2026-11-02/`(`clone-fixture.sh`, `verify-050.sh`, `bulkprobe`)에 있습니다.

버전은 0.4.0을 건너뛰지 않고 0.5.0으로 올렸습니다. 설치본에 0.4.0이라 표시된 옛 빌드가 있어 같은 번호로는 자동 업데이트가 뜨지 않기 때문입니다.

## 2026-11-02 — 디스크보다 큰 합계(506GB) 진단: APFS clone 중복 집계

- 변경 파일: 코드 변경 없음. 측정 도구와 결과는 `~/Bufs/Claude Files/2026-11-02/`(`clonestat`, `dedupe`, `engine-probe.sh`)
- 요약: 245GB 디스크에서 합계가 506GB로 나왔습니다. `/private/var/folders/.../X/com.google.Chrome.code_sign_clone`의 Chrome 복사본 119개가 271GB로 잡힌 것이 대부분이고, clone ID로 한 번씩만 세면 디스크 전체가 489GB에서 206GB로 줄어 `df`와 맞습니다. 수정은 아직 하지 않았습니다.

⚠️ **`ATTR_FILE_ALLOCSIZE`와 `totalFileAllocatedSize`는 APFS clone마다 전체 크기를 돌려줍니다.** 하드링크는 inode로 걸러졌지만 clone은 inode가 달라서 그대로 합산됩니다. `ATTR_CMNEXT_CLONEID`(`forkattr`, `FSOPT_ATTR_CMN_EXTENDED`)를 `getattrlistbulk`로 받으면 파일별 clone ID가 나오고, 이 조회를 더해도 스캔 시간은 그대로였습니다(27.7초 대 28초). 복사본 폴더의 실제 고유 데이터는 3.04GB이고 그중 2.28GB는 설치된 Chrome.app과 공유합니다. 지워서 돌아오는 공간은 271GB가 아니라 약 0.8GB입니다. 그래서 이 숫자를 그대로 에이전트에 넘기면 "271GB 확보 가능"이라는 잘못된 판정이 나옵니다. 지금 문구(`cloneNote`)로 안내하는 것만으로는 부족합니다.

**10-28의 속도 수치는 캐시가 데워진 값입니다.** `compare.sh`가 기존 엔진을 먼저 돌렸기 때문에 새 엔진은 늘 데워진 캐시를 읽었습니다. 다시 재보니 같은 데워진 상태에서 기존 엔진 507초(앞선 회차 290초), 새 엔진 28초로 차이는 실제로 큽니다. 다만 캐시가 식으면 새 엔진도 355초가 걸립니다(프로토타입 첫 실행은 215초). 이 Mac은 메모리 압박으로 file-backed 페이지가 1.7GB 안팎이라 몇 분만 지나도 캐시가 밀려납니다. README의 "about 15 s"는 고쳐야 합니다. 앞으로 엔진을 비교할 때는 순서를 바꿔가며 두 번씩 재고, 비교 스크립트 순서로 한쪽만 이득을 보지 않게 해야 합니다.

**같은 버전 번호에 빌드가 두 개입니다.** 10-28 12:44에 설치한 LaunchServices 수정 빌드와 이후 병렬 엔진 빌드가 모두 0.4.0입니다. 앱이 열려 있어 뒤쪽 설치가 멈춘 뒤로, 설치본은 0.4.0이라고 표시되지만 옛 엔진(`nm -u`에 `getattrlistbulk` 없음)입니다. 이 상태로 v0.4.0을 릴리스하면 `isNewer`가 false라 설치본이 업데이트를 받지 못하므로, 다음 릴리스는 0.4.1 이상이어야 합니다.

복사본이 쌓이는 원인: Chromium의 `CodeSignCloneManager`는 브라우저 시작 때 앱을 `clonefile`로 복사하고, 소멸자에서만 정리 helper를 띄웁니다. 코드상 강제 종료되면 정리가 실행되지 않고, 오래된 복사본을 치우는 로직도 없습니다(TODO만 있음). 소스 주석에 따르면 `X` 폴더는 부팅 때 비워집니다. 가동 시간 7일 21시간과 가장 오래된 복사본(10-25)이 일치합니다. 복사본 122개 중 55개는 45초 안에 에이전트 세션의 브라우저 관련 명령(headless Chrome을 직접 띄우는 스크립트 49건 포함)이 있었습니다. 나머지 67개의 출처와 그 스크립트들의 종료 방식은 확인하지 못했습니다.

## 2026-10-28 — 병렬 스캔 엔진(6~9배), "AI로 용량 확보하기", 오래된 판정 숨김

- 변경 파일: `Core/Scanner.swift`(다시 작성), `Core/FileNode.swift`, `Model/AppState.swift`, `Model/AgentChat.swift`, `Model/AnnotationCenter.swift`, `Views/AgentSidebar.swift`, `App/ContentView.swift`
- 요약: 스캔을 `getattrlistbulk` + 병렬 작업 큐로 바꿨습니다. 홈 폴더 145만 파일은 51초에서 5.9초로, 디스크 전체 267만 파일은 96초에서 14.7초(앱 화면에서는 실시간 차트 포함 20.6초)로 줄었습니다. 메인 화면에 "AI로 용량 확보하기"를 추가했습니다. 에이전트를 고르면 전체 스캔이 끝난 뒤 분석이 자동으로 나갑니다.

느린 원인은 DFS 자체가 아니라 **스레드 하나로 순서대로 읽는 구조**였습니다. 기존 엔진은 CPU 26초에 실제 55초가 걸려, 절반 이상을 메타데이터 응답을 기다리며 놀았습니다. `getattrlistbulk`만으로는 33초였고, 병렬 8개에서 6.5초, 16개에서 5.7초였습니다. 16개는 커널 CPU만 두 배로 늘어서, 작업 스레드는 코어 수(4~12개)로 정했습니다. 디렉터리 하나를 다 읽은 뒤 트리 잠금을 한 번 잡고 자식 설치와 크기 반영을 하므로, 파일 단위 잠금이 없습니다. 진행 상황과 차트 스냅숏은 별도 감시 스레드가 같은 잠금 아래에서 만듭니다.

⚠️ **`getattrlistbulk`의 버퍼 배치를 가정하면 안 됩니다.** `ATTR_CMN_ERROR`는 비트 순서와 무관하게 반환 속성 집합 바로 뒤에 오고, 디렉터리 속성은 디렉터리 항목에만, 파일 속성은 파일 항목에만 들어옵니다(`FSOPT_PACK_INVAL_ATTRS`를 줘도 그랬음). 고정 배치로 읽었다가 하드링크 크기를 엉뚱한 곳에서 읽어 산술 오버플로로 죽었습니다. 지금은 항목마다 반환 비트를 보고 있는 속성만 읽습니다.

⚠️ **마운트 지점은 아래쪽 파일 시스템의 장치 번호를 돌려줍니다.** 장치 번호만 비교하면 다른 볼륨으로 들어갑니다. `ATTR_DIR_MOUNTSTATUS`가 마운트 지점이면 그때만 `stat`으로 실제 장치를 확인합니다. firmlink 중복은 기존 DFS 순서 대신 2단계로 막습니다. `/System/Volumes/Data`를 따로 미뤄뒀다가 나머지가 다 끝난 뒤 처리하고, 이미 본 inode는 건너뜁니다.

결과 검증: 두 엔진을 같은 내보내기 경로로 돌려 비교했습니다. `~/Bufs`는 파일 수와 바이트까지 일치했습니다. 홈과 디스크 전체는 새 엔진이 약 1,300개 더 셌는데, 원인은 **`FileManager.contentsOfDirectory`가 `._` AppleDouble 파일을 목록에서 빼기** 때문입니다(`__MACOSX` 폴더 하나에서 `ls` 143개, FileManager 0개). 새 값이 `du`와 맞습니다. 권한 거부 수(286)는 같습니다.

파일 노드 수백만 개의 비용도 줄였습니다. 노드마다 있던 URL 객체와 UUID를 없애고, 경로는 부모를 따라 필요할 때 만들며, 식별자는 객체 자체를 씁니다. 그래서 경로로 노드를 찾을 때는 URL 대신 이름을 비교하고, 목록 행은 이름으로 식별하고, 스냅숏 사본은 부모 사본의 경로에 이름만 붙입니다(잠금을 잡은 채 경로를 처음부터 조립하지 않게).

판정 배너가 앱을 켜자마자 뜬 원인은 시험용 판정이 파일에 남아 있어서였습니다. 앱 시작 2분 전보다 오래된 판정은 숨깁니다. 2분의 여유는, 에이전트가 판정을 쓰고 바로 `open_app`으로 앱을 여는 흐름 때문입니다.

## 2026-10-28 — "DiskLens 응용 프로그램을 더 이상 열 수 없습니다" 수정

- 변경 파일: `Sources/DiskLens/App/Entry.swift`
- 요약: 0.3.0부터 `--mcp` 프로세스가 LaunchServices에 "실행 중인 DiskLens"로 등록돼서, 앱을 열면 macOS가 그 프로세스를 앞으로 불러오려다 실패했습니다. `--mcp`에서는 AppKit을 쓰지 않게 했습니다.

⚠️ **`--mcp` 경로에서 `NSApplication.shared`를 부르면 안 됩니다.** 화면 없는 실행에서 Dock 아이콘을 숨기려고 `NSApplication.shared.setActivationPolicy(.prohibited)`를 불렀는데, 이 호출 자체가 프로세스를 앱 인스턴스로 등록합니다(`lsappinfo list`에 `bundleID="com.jaewonbaek.disklens"`로 나오고, 하나는 `type="Foreground"`였음). MCP 서버는 Claude Code 세션이 오래 붙잡고 있고, 백그라운드 작업용 예비 세션(`claude bg-spare`)도 사용자 범위 MCP를 미리 띄웁니다. 그래서 Claude Code를 쓰지 않을 때도 앱이 안 열렸습니다. 같은 이유로 자동 업데이트의 마지막 단계(`open` 재실행)도 실패했을 겁니다. 이제는 LaunchServices로 띄우는 `--export`에서만 Dock 숨김을 씁니다. 확인 방법: `--mcp`로 띄운 뒤 `lsappinfo list | grep -c "pid = <pid> "`가 0이어야 합니다.

## 2026-10-28 — AI 사이드바: Claude Code·Codex 대화, 모델 선택, 생각·작업 표시 (0.4.0)

- 변경 파일: `Agents/`(새로 추가), `Model/AgentChat.swift`, `Views/AgentSidebar.swift`, `Core/CurrentScan.swift`, `Views/MarksBanner.swift`(`ClaudeBanner`에서 이름 변경), 기존 화면과 `MCPServer`
- 요약: 툴바 오른쪽 끝의 ✨ 버튼 하나로 에이전트·모델·추론 강도를 고르면, 상세 분석 프롬프트가 입력창에 채워진 채로 채팅이 열립니다. 보내기 전에는 아무것도 실행하지 않습니다. 사이드바는 생각, 도구 단계(진행·성공·실패, 시간, 결과), 턴별 시간·토큰을 보여줍니다.

에이전트마다 SDK를 붙이지 않고, 이미 설치된 CLI를 프로세스로 띄웁니다. 사용자의 로그인과 구독을 그대로 쓰기 위해서입니다. 두 CLI는 동작 방식이 다릅니다. Claude Code는 프로세스 하나에 stdin으로 stream-json 턴을 보내고, Codex는 턴마다 `codex exec`나 `exec resume <thread>`를 띄웁니다. 그래서 `AgentDriver`는 `send`·`stop`·`shutdown`만 정의하고, 이벤트(글자, 생각, 도구 시작·종료, 휴지통, 사용량, 종료)를 같은 형식으로 올립니다. 대화 화면, 권한 정책, 지침은 공통입니다.

⚠️ **사이드바는 사용자 설정을 읽으면 안 됩니다.** 이 Mac의 `~/.claude/settings.json`은 `defaultMode: bypassPermissions`라서, 허용 목록을 줘도 `touch`가 질문 없이 실행됐습니다(시험에서 실제로 파일이 생김). 그래서 Claude는 `--setting-sources project --permission-mode default --add-dir /`로 실행하고, Codex는 `--ignore-user-config`와 `sandbox_mode="read-only"`를 씁니다. 두 경우 모두 읽기 전용 명령만 통과하고 쓰기는 거부되는 것을 확인했습니다. 대가로 사용자 skill도 안 보이므로, storage-cleanup의 `SKILL.md`와 `hotspots.md`를 시스템 프롬프트(Claude) 또는 `developer_instructions`(Codex)에 넣습니다. 지침의 `rm -rf`와 스크립트보다 "휴지통 이동만" 규칙이 우선한다고 명시해뒀습니다.

사용자 설정을 끄면 모델 설정도 사라집니다. 그래서 사용자 설정의 모델과 추론 강도를 읽어 기본 선택값으로 쓰고, CLI에는 명시적으로 넘깁니다. Codex에는 함정이 있었습니다. 설정의 `gpt-6.1-sol`은 계정 모델 목록(`~/.codex/models_cache.json`)에 없어서 "not supported when using Codex with a ChatGPT account"로 거부됐습니다. 그래서 목록에 있는 모델만 보여주고, 사용자 설정의 모델은 목록에 있을 때만 기본값으로 씁니다. Codex는 MCP 호출도 승인 대상이라 `mcp_servers.disklens.default_tools_approval_mode="approve"`가 필요합니다(값은 `auto`·`prompt`·`writes`·`approve`). 추론 요약은 `model_reasoning_summary="auto"`를 켜야 옵니다. `exec resume`은 `-s`와 `-m`을 받지 않으므로 모든 설정을 `-c`로 넘깁니다.

스트림을 읽을 때 함정 두 가지. 파이프의 `readabilityHandler`는 EOF에서 빈 데이터로 계속 불리므로 해제해야 합니다(Codex는 턴마다 프로세스가 끝남). 조각마다 `Task { @MainActor }`를 쓰면 순서가 보장되지 않아서 `DispatchQueue.main.async`로 넘깁니다. 중지한 턴의 늦은 이벤트는 `AgentChat`이 턴이 진행 중일 때만 받는 방식으로 버립니다. Claude가 생각 내용을 보내지 않으면 빈 thinking이 오므로, 내용이 없고 1.5초 미만인 생각 조각은 지웁니다. Codex는 추론 요약을 끝났을 때만 주는 경우가 많아서, 1초 미만이면 시간 대신 "생각 요약"으로만 표시합니다.

앱의 스캔은 화면에 넘기기 전에 스캔 스레드에서 `current-scan.json`(1MB 이상 항목)으로 저장합니다. MCP의 `current_scan`과 `list`가 이 파일을 읽어서, 에이전트가 다시 스캔하지 않고 사용자가 보는 트리를 그대로 봅니다. 판정의 출처는 MCP `initialize`의 `clientInfo`로 구분해서, 배너에 "Claude가…"나 "Codex가…"로 표시합니다. 창 기본 크기는 1240×780이고, 사이드바를 열면 최소 너비를 1080으로 올리고 창을 넓힙니다.

시험은 임시 자체 시험 코드(환경 변수로 실제 진입 함수를 순서대로 호출)로 앱 안에서 했고, 커밋 전에 지웠습니다. 두 에이전트 모두 확인한 것: 선택창 → 확인 → 프롬프트가 채워짐 → 보내기, 판정 기록, 휴지통 이동 뒤 차트 동기화, 대화 이어가기, 생각·단계·토큰 기록.

## 2026-10-28 — 에이전트 연동: JSON 내보내기, MCP 서버, Claude 판정 표시 (0.3.0)

- 변경 파일: `Sources/DiskLens/App/Entry.swift`, `Headless/`, `Core/UsageTree.swift`, `Core/Annotations.swift`, `Model/AnnotationCenter.swift`, `Views/ClaudeBanner.swift`와 기존 화면 3개
- 요약: Claude Code의 `storage-cleanup` skill이 DiskLens 엔진을 쓰도록 `--export`(JSON)와 `--mcp`(stdio MCP 서버)를 추가했습니다. Claude가 남긴 판정(`annotations.json`)은 앱의 배너, 목록 배지, 차트 테두리로 보여줍니다.

내보내기와 MCP는 같은 `UsageNode` 트리를 씁니다. 최소 크기보다 작은 항목은 각 폴더의 `otherSize`로 접어 넣기 때문에, 홈 폴더(142만 파일)도 50MB 기준이면 JSON 353KB입니다. MCP 서버는 스캔 결과를 메모리에 두고 `list`와 `largest_files`에 바로 답합니다. `du`를 여러 번 도는 대신 한 번 스캔한 뒤 조회하게 만든 것이 핵심입니다. 화면이 없을 때는 `Scanner.liveSnapshots = false`로 차트용 스냅숏(초당 20회 트리 복사)을 건너뜁니다.

판정을 앱에 넘기는 통로로는 파일(`~/Library/Application Support/DiskLens/annotations.json`)을 골랐습니다. MCP 서버는 Claude Code가 띄우는 별도 프로세스라 앱과 메모리를 공유하지 않고, 파일로 넘기면 MCP 없이 skill이 직접 써도 됩니다. 앱은 2초마다 수정 시각만 확인합니다.

⚠️ **`NSTreatUnknownArgumentsAsOpen`을 지우면 안 됩니다.** AppKit은 경로처럼 생긴 실행 인자를 "열 문서"로 처리하는데, SwiftUI 앱은 실행하면서 문서를 열면 첫 창을 만들지 않습니다. 그래서 README의 `open -a DiskLens --args /folder`는 0.2.0에서도 창 없이 대기만 했습니다. `Entry`에서 이 기본값을 `NO`로 등록해 고쳤습니다.

⚠️ **전체 디스크 접근 권한은 "책임 프로세스"를 따라갑니다.** 터미널에서 바이너리를 직접 실행하면 터미널의 권한으로 스캔합니다. DiskLens 자신의 권한을 쓰려면 `open -n -W -a DiskLens --args --export /abs/path.json <folder>`로 LaunchServices를 거쳐야 하고, 출력 경로는 절대 경로여야 합니다. `--mcp`는 Claude Code가 직접 띄우므로 이 방법을 쓸 수 없습니다. 화면 없이 실행할 때는 `setActivationPolicy(.prohibited)`로 Dock 아이콘이 생기지 않게 했습니다.

`move_to_trash`는 홈 폴더 아래와 `/Applications`만 허용하고, 홈 바로 아래 폴더(`~/Library` 등)는 통째로 옮기지 못하게 막았습니다. 휴지통으로 옮겨도 비우기 전에는 공간이 돌아오지 않는다는 점을 응답에 항상 넣습니다.

시험 중 함정: Claude Code의 백그라운드 세션에서 `open -n`으로 띄운 앱은 창이 뜨지 않았습니다(0.2.0도 같음). 화면이 필요한 확인은 바이너리를 직접 실행해서 해야 합니다. 그 세션에는 화면 기록 권한도 없어서 `screencapture -l`이 실패합니다.
