import DonkeyUI
import SwiftUI

struct PointerPromptOverlayRootView: View {
    @ObservedObject var model: PointerPromptOverlayModel

    var body: some View {
        PointerPromptStageView(
            state: model.promptState,
            messageText: $model.messageText,
            placement: model.placement,
            intentSink: model
        )
        .frame(
            width: PointerPromptOverlayController.contentSize.width,
            height: PointerPromptOverlayController.contentSize.height
        )
    }
}
