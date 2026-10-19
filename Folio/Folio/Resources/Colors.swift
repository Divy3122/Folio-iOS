//
//  Colors.swift
//  Folio
//
//  Created by Ziyan Nadeem on 20/10/2026.
//


import SwiftUI

extension Color {
    // MARK: - Brand
    static let BrandNavy = Color(
        light: 0x142B4A,
        dark: 0xA9C7F5
    )

    static let BrandTeal = Color(
        light: 0x087F7B,
        dark: 0x5EE5D8
    )

    // MARK: - Backgrounds
    static let AppBackground = Color(
        light: 0xF5F7FA,
        dark: 0x0B1220
    )

    static let CardBackground = Color(
        light: 0xFFFFFF,
        dark: 0x172338
    )

    // MARK: - Text
    static let PrimaryText = Color(
        light: 0x142B4A,
        dark: 0xF1F5F9
    )

    static let SecondaryText = Color(
        light: 0x64748B,
        dark: 0xB0BDCE
    )

    // MARK: - Borders
    static let BorderColor = Color(
        light: 0xD8E0EA,
        dark: 0x34445A
    )

    // MARK: - Status
    static let SuccessGreen = Color(
        light: 0x15803D,
        dark: 0x4ADE80
    )

    static let WarningAmber = Color(
        light: 0xB45309,
        dark: 0xFBBF24
    )

    static let ErrorRed = Color(
        light: 0xB91C1C,
        dark: 0xFCA5A5
    )

    // MARK: - Controls
    static let DisabledColor = Color(
        light: 0xCBD5E1,
        dark: 0x475569
    )

    // MARK: - Helpers

    private init(light: UInt, dark: UInt) {
        self.init(
            uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark
                    ? dark
                    : light

                return UIColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            }
        )
    }
}
