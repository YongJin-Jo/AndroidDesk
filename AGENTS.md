# AndroidDesk 개발 지침

## AppKit 네이티브 구현 원칙

- macOS UI와 사용자 상호작용 기능은 반드시 AppKit의 공개 네이티브 API와 메서드로 구현한다.
- 테이블 선택, 행 갱신, 클릭, 키보드 입력, 포커스, 우클릭 메뉴, 인라인 편집, 드래그 앤 드롭은 `NSTableView`, `NSTableRowView`, `NSTextField`, `NSMenu`, `NSResponder`, `NSDraggingSession` 등 해당 AppKit API를 직접 사용한다.
- SwiftUI는 화면 구성, 상태 전달, AppKit 뷰 연결 용도로만 사용한다. AppKit에서 제공하는 기능을 SwiftUI 제스처, 투명 오버레이, 임의 타이머 또는 수동 좌표 계산으로 재구현하지 않는다.
- AppKit 네이티브 기능이 있는데 별도의 커스텀 동작을 추가하거나 기존 네이티브 동작을 가로채지 않는다.
- 필요한 AppKit 공개 API가 존재하지 않는 경우에는 비네이티브 우회 구현을 적용하기 전에 한계와 대안을 사용자에게 설명하고 승인을 받는다.
- 구현 전 현재 macOS SDK 헤더와 AppKit 공개 API를 확인하고, 더 이상 권장되지 않는 API나 비공개 API는 사용하지 않는다.
