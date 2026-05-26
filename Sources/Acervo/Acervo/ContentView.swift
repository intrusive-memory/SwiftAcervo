//
//  ContentView.swift
//  Acervo
//
//  Hosts a single AcervoModelsSection backed by the real static Acervo
//  API. No mocks — every closure delegates to the production library.
//

import SwiftUI
import SwiftAcervo
import SwiftAcervoUI

struct ContentView: View {

  var body: some View {
    Form {
      AcervoModelsSection(
        items: FixtureModels.demoFixtures,
        header: "Models",
        availability: { item in
          await Acervo.availability(item.id)
        },
        download: { item, progress in
          try await Acervo.ensureAvailable(
            item.id,
            files: [],
            progress: { tick in
              // AcervoDownloadProgress.overallProgress is the byte-accurate
              // cumulative fraction across every manifest file, exactly the
              // 0.0…1.0 sink the row expects.
              progress(tick.overallProgress)
            }
          )
        },
        deleteModel: { item in
          try Acervo.deleteModel(item.id)
        }
      )
    }
    #if os(macOS)
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 360)
    #endif
  }
}

#Preview {
  ContentView()
}
