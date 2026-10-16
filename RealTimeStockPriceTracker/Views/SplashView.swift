//
//  SplashView.swift
//  RealTimeStockPriceTracker
//
//  Created by Somdev Choudhary on 15/10/26.
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            background
            content
        }
    }

    private var background: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }

    private var content: some View {
        VStack(alignment: .center, spacing: 25) {
            Spacer()
            logo
            title
            Spacer()
            copyright
        }
        .padding()
    }

    private var logo: some View {
        Image("multibankgroup")
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 20)
    }

    private var title: some View {
        Text("Real Time Stock \nPrice Tracker")
            .multilineTextAlignment(.center)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.primary)
    }

    private var copyright: some View {
        Text("© MultiBank Group")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
    }
}

#Preview {
    SplashView()
}
