//
//  printDebug.swift
//  iCook
//
//  Created by George Babichev on 9/23/25.
//

import SwiftUI

func printD(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    //print(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
    #endif
}
