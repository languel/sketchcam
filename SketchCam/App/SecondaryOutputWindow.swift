import SwiftUI

struct SecondaryOutputWindow: View {
    @ObservedObject var model: SketchCamViewModel

    var body: some View {
        ZStack {
            Color.black
            SampleBufferDisplayView(controller: model.secondaryOutputDisplay)
                .aspectRatio(
                    CGFloat(model.outputFormat.width) / CGFloat(max(1, model.outputFormat.height)),
                    contentMode: .fit
                )
        }
        .frame(
            minWidth: 320,
            idealWidth: max(320, model.outputFormat.size.width / 2),
            minHeight: 180,
            idealHeight: max(180, model.outputFormat.size.height / 2)
        )
        .background(Color.black)
    }
}
