//
//  Item.swift
//  CleanLivePhotos
//
//  Created by RENJIAWEI on 2025/6/11.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
