# 하단 썸네일 스트립 스크롤바 표시 — CenterView.swift 수정 요청

## 수정 대상 파일

`pinframe/pinframe/CenterView.swift`

---

## 수정 내용

`ThumbnailStrip` 내부의 `ScrollView` 에서 `showsIndicators: false` → `true` 로 변경:

```swift
// 변경 전
ScrollView(.horizontal, showsIndicators: false) {

// 변경 후
ScrollView(.horizontal, showsIndicators: true) {
```

---

## 확인 항목

썸네일이 뷰 너비를 넘길 만큼 많을 때 하단에 가로 스크롤바가 표시되는지 확인.
