import DonkeyContracts
import DonkeyUI
import SwiftUI

struct PointerPromptOverlayRootView: View {
    @ObservedObject var model: PointerPromptOverlayModel

    var body: some View {
        PointerPromptStageView(
            state: model.promptState,
            messageText: $model.messageText,
            inputTextHeight: model.inputTextHeight,
            placement: model.placement,
            intentSink: model
        )
        .frame(
            width: PointerPromptLayout.contentSize(inputTextHeight: model.inputTextHeight).width,
            height: PointerPromptLayout.contentSize(inputTextHeight: model.inputTextHeight).height
        )
    }
}
