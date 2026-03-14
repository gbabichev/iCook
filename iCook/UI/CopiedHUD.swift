//
//  CopiedHUD.swift
//  iCook
//
//  Created by George Babichev on 9/23/25.
//


import SwiftUI

struct CopiedHUD: View {
    let message: String

    init(message: String = "Copied to Clipboard") {
        self.message = message
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text(message)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(radius: 6)
    }
}
