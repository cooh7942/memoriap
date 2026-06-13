import SwiftUI

struct CopyMoveConfirmDialog: View {
    let sourceCount: Int
    let destinationName: String
    @Binding var focusedChoice: ClipboardMode
    let onChoose: (ClipboardMode?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(sourceCount)개 항목을 어떻게 처리할까요?")
                    .font(.headline)
                Text("대상 폴더: '\(destinationName)'")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Spacer()
                dialogButton(title: "취소", isFocused: false, kind: .neutral) {
                    onChoose(nil)
                }
                dialogButton(title: "복사", isFocused: focusedChoice == .copy, kind: .neutral) {
                    onChoose(.copy)
                }
                dialogButton(title: "이동", isFocused: focusedChoice == .cut, kind: .primary) {
                    onChoose(.cut)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    private enum ButtonKind { case primary, neutral }

    @ViewBuilder
    private func dialogButton(title: String, isFocused: Bool,
                              kind: ButtonKind, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(title)
                .fontWeight(isFocused ? .semibold : .regular)
                .foregroundColor(kind == .primary ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(kind == .primary ? Color.accentColor : Color.gray.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: isFocused ? 2.5 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}
