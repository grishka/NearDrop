//
//  QrCodeView.swift
//  NearDrop
//
//  Created by Leon Böttger on 10.03.25.
//

import SwiftUI

let qrCodeViewSize = CGSize(width: 530.0, height: 270.0)

struct QrCodeView: View {
    @State private var qrCode: String = ""
    let closeView: () -> Void
    
    var body: some View {
  
        VStack {
            
            Button(action: {
                closeView()
            }, label: {
                Image("xmark")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .opacity(0.5)
            })
            .buttonStyle(PlainButtonStyle())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 15)
            .padding(.top, 15)
            
            HStack {
                Spacer()
                
                Image("QR")
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(height: 190)
                
                Spacer()
                
                
                Text("QrCodeInstructions".localized())
                    .padding(.top, 5)
                    .padding(.horizontal)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom)
            
            Spacer()
        
        }
        .frame(width: qrCodeViewSize.width, height: qrCodeViewSize.height)
    }
}


public extension String {
    func localized() -> String {
        let localizedString = NSLocalizedString(self, comment: "")
        return localizedString
    }
}


#Preview {
    QrCodeView(closeView: {})
}
