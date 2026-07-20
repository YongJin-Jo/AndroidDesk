# AndroidDesk

MTP로 연결된 Android 기기와 macOS 사이에서 파일을 전송하는 SwiftUI 앱입니다. USB 디버깅이나 ADB 권한이 필요하지 않습니다.

## 기능

- 연결된 MTP 기기 확인
- 사용자 홈 폴더에서 시작하는 Mac 파일 탐색 및 폴더 이동
- Mac 파일 또는 폴더를 드래그앤드롭해 Android 폴더로 업로드
- Android MTP 폴더 목록 보기
- 선택한 Android 파일 또는 폴더를 Mac으로 다운로드

## 구조

- Swift Package Manager로 앱, C 브리지, `libmtp` 시스템 라이브러리 의존성 관리
- SwiftUI 화면과 `AndroidDeviceViewModel`을 분리한 MVVM 구조
- `MTPServicing` 프로토콜을 통한 의존성 주입
- `MTPService` actor에서 USB 작업을 직렬 처리

별도 아키텍처 프레임워크는 사용하지 않습니다. 현재 규모에서는 SwiftUI와 Swift Concurrency만으로 충분하며, 서비스 프로토콜을 교체해 테스트용 구현을 주입할 수 있습니다.

## 준비

macOS에는 MTP 파일 전송 API가 기본 제공되지 않으므로 `libmtp`가 필요합니다.

```sh
brew install libmtp
```

휴대폰 잠금을 해제한 뒤 USB 설정에서 **파일 전송 / Android Auto** 모드를 선택하세요. MTP 장치는 한 번에 하나의 앱에서만 사용할 수 있으므로 OpenMTP, Android File Transfer 등 다른 MTP 앱이 실행 중이면 종료해야 합니다.

## 실행

Xcode에서 `Package.swift`를 열어 실행하거나, Terminal에서 아래 명령을 실행합니다.

```sh
cd ~/AndroidDesk
swift run AndroidDesk
```

Android 폴더는 기본 저장소의 루트(`/`)에서 시작합니다. 폴더를 두 번 클릭해 이동하거나 경로를 직접 입력하세요. 기기별로 다운로드 폴더 이름이 `Download`, `Downloads` 등으로 다를 수 있습니다.
