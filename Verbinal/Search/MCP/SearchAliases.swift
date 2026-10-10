// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Search's tools under the names Verbinal for Windows gives them.
enum SearchAliases {
    static func getDataTrainOptions(_ inner: GetDataTrainOptionsTool) -> AliasedToolBox<GetDataTrainOptionsTool> {
        AliasedToolBox(name: "get_data_train_options", description: "Alias of `get_search_constraints`.", inner: inner)
    }

    static func setADQLEditor(_ inner: SetADQLEditorTool) -> AliasedToolBox<SetADQLEditorTool> {
        AliasedToolBox(name: "set_adql_editor", description: "Alias of `set_adql_query`.", inner: inner)
    }

    static func setResultsView(_ inner: SetResultsViewTool) -> AliasedToolBox<SetResultsViewTool> {
        AliasedToolBox(name: "set_results_view", description: "Alias of `set_search_results_view`.", inner: inner)
    }
}
