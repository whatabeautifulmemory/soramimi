# Soramimi

<p align="center">
  <img src="assets/header.png" alt="Soramimi - pixel-art jazz singer" width="480">
</p>

두 가지 기능을 하는 아주 작은 macOS 메뉴 막대 유틸리티입니다:

1. **Bluetooth keep-alive** (예: Marshall Bluetooth 스피커) — 들리지 않는 연속 신호와 주기적인 16 kHz wake ping으로 스피커가 절전에 들어가거나 연결이 끊기지 않게 유지합니다.
2. **Apple Music / iTunes blocker** ([noTunes](https://github.com/tombonez/noTunes)가 제공하는 것과 동일한 기능) — 원치 않는 Apple Music/iTunes 자동 실행을 막고, 대신 지정한 앱이나 URL을 열 수 있습니다.

메뉴 막대 전용. 네트워크·텔레메트리 없음, 관리자 권한 불필요, Accessibility 권한 불필요, 다른 플레이어나 Now Playing/미디어 키 세션을 건드리지 않습니다. 모든 기능은 **기본 OFF**입니다.

## 빠른 사용

### 다운로드

GitHub Releases에서 `Soramimi-1.0.0.zip`을 내려받아 `Soramimi.app`을 `/Applications`로 옮기고 실행합니다.

### Homebrew

```bash
brew update
brew tap whatabeautifulmemory/soramimi https://github.com/whatabeautifulmemory/soramimi
brew install --cask soramimi
```

### 소스에서 빌드

```bash
make build
make install
```

1. 메뉴 막대 아이콘을 클릭하고 **Bluetooth Keep-Alive**를 켭니다.
2. `Output Device`가 Bluetooth 스피커인지, 시스템 음량이 음소거가 아닌지 확인합니다.
3. **Wake Ping**은 기본 ON(5분마다, −18 dBFS)이며 필요하면 조정합니다.
4. 필요하면 **Block Apple Music**을 켜고 Always/Smart 정책과 대체 앱 또는 URL, **Launch at Login**을 설정합니다.

## 기능 소개

### Bluetooth Keep-Alive (예: Marshall Bluetooth 스피커)
- 440 Hz, 0.1초 무이음 루프를 −100 dBFS로 연속 재생(−100…−60 조절).
- 16 kHz, 0.5초 wake ping을 기본 5분마다 재생(Off/1/2/5/10분; −30…−6 dBFS).
- 기본 출력 장치 변경, Bluetooth 재연결, 시스템 절전/깨우기를 따라가며, 출력 장치나 볼륨은 바꾸지 않습니다.

### Apple Music / iTunes Blocker ([noTunes](https://github.com/tombonez/noTunes)와 동일한 기능)
- **Always Block** 또는 **Smart Block**; 앱 창이 뜨기 전에 차단합니다.
- 선택적으로 대체 앱 또는 `http(s)` URL 실행.
- iTunes가 설치되어 있지 않으면 관련 항목을 숨깁니다.

## 요구사항

- macOS 13 이상.
- 빌드에는 Xcode Command Line Tools.
- 빌드·설치·실행에 관리자 권한 불필요.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
