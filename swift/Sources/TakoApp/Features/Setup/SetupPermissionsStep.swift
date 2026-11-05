// Tako — setup permissions
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import SwiftUI

@MainActor
struct SetupPermissionsStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        SetupPermissionPanel(model: model).frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
    }
}
