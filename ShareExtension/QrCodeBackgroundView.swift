//
//  QrCodeBackgroundView.swift
//  ShareExtension
//
//  Created by Grishka on 07.08.2025.
//

import Foundation
import Metal
import MetalKit

class QrCodeBackgroundView:MTKView{
	private var commandQueue:MTLCommandQueue?
	private var commandBuffer:MTLCommandBuffer?
	
	override func awakeFromNib() {
		super.awakeFromNib()
		isPaused=true
		enableSetNeedsDisplay=false
		device=MTLCreateSystemDefaultDevice()
		let brightness=1.5
		clearColor=MTLClearColor(red: brightness, green: brightness, blue: brightness, alpha: 1)
		
		let mtlLayer:CAMetalLayer=(layer as? CAMetalLayer)!
		mtlLayer.wantsExtendedDynamicRangeContent=true
		mtlLayer.cornerRadius=20
		mtlLayer.masksToBounds=true
		colorspace=CGColorSpace(name: CGColorSpace.extendedSRGB)
		colorPixelFormat = .rgba16Float
		
		commandQueue=device!.makeCommandQueue()
		commandBuffer=commandQueue!.makeCommandBuffer()
		draw()
	}
	
	override func draw(_ dirtyRect: NSRect) {
		guard let commandBuffer=commandBuffer else {return}
		if let descriptor=currentRenderPassDescriptor, let encoder=commandBuffer.makeRenderCommandEncoder(descriptor: descriptor){
			encoder.endEncoding()
			if let currentDrawable=currentDrawable{
				commandBuffer.present(currentDrawable)
			}
		}
		commandBuffer.commit()
	}
}
