import SwiftUI

enum DeleteConfirmChoice {
    case trash
    case cancel
}

struct DeleteConfirmDialog: View {
    let photoName: String
    @Binding var skipNextTime: Bool
    @Binding var focusedChoice: DeleteConfirmChoice
    let onChoose: (DeleteConfirmChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("사진을 휴지통으로 이동하시겠습니까?")
                    .font(.headline)
                Text("'\(photoName)'")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Toggle("다시 묻지 않기", isOn: $skipNextTime)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Spacer()
                dialogButton(title: "취소", isDestructive: false,
                             isFocused: focusedChoice == .cancel) { onChoose(.cancel) }
                dialogButton(title: "휴지통으로 이동", isDestructive: true,
                             isFocused: focusedChoice == .trash) { onChoose(.trash) }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    @ViewBuilder
    private func dialogButton(title: String, isDestructive: Bool,
                              isFocused: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(title)
                .fontWeight(isFocused ? .semibold : .regular)
                .foregroundColor(isDestructive ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDestructive ? Color.red : Color.gray.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: isFocused ? 2.5 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}
