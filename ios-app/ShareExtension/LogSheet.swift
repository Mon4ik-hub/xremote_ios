import SwiftUI
import UIKit

/// Журнал работы панели: посмотреть и скопировать для диагностики.
struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText.isEmpty ? "Журнал пуст" : logText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .navigationTitle("Журнал")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Скопировать") {
                        UIPasteboard.general.string = logText
                        logText = AppLog.shared.text() // обновить после перезаписи буфера
                    }
                    Button("Очистить") {
                        AppLog.shared.clear()
                        logText = ""
                    }
                }
            }
        }
        .onAppear { logText = AppLog.shared.text() }
    }
}
