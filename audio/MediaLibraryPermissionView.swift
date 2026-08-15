//
//  MediaLibraryPermissionView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI

struct MediaLibraryPermissionView: View {
    let state: MediaLibraryAccessState
    let accentColor: Color
    var isLoading = false
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // アイコン
            ZStack {
                Circle()
                    .stroke(Theme.border, lineWidth: 1)
                    .frame(width: 100, height: 100)
                
                Image(systemName: state == .denied ? "lock.fill" : "music.note.list")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(accentColor)
            }
            
            // テキスト
            VStack(spacing: 16) {
                Text(title)
                    .font(.title2.weight(.light))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                
                Text(description)
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            // ボタン
            if state != .denied {
                Button(action: action) {
                    LoadingButtonLabel(
                        title: L10n.tr("permission.allow_access"),
                        isLoading: isLoading,
                        accentColor: .black
                    )
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 32)
                        .background(accentColor)
                        .clipShape(Capsule())
                }
                .disabled(isLoading)
                .padding(.top, 10)
            } else {
                Text(L10n.tr("permission.open_settings_hint"))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }
    
    private var title: String {
        switch state {
        case .denied: return L10n.tr("permission.title.denied")
        case .restricted: return L10n.tr("permission.title.restricted")
        default: return L10n.tr("permission.title.default")
        }
    }
    
    private var description: String {
        switch state {
        case .denied:
            return L10n.tr("permission.description.denied")
        case .restricted:
            return L10n.tr("permission.description.restricted")
        default:
            return L10n.tr("permission.description.default")
        }
    }
}
