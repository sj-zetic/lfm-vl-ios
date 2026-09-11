package com.sjk.lfmvision.android

import android.content.Context
import android.content.Intent
import android.content.ClipData
import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import java.io.File

@Composable
fun VisionScreen(viewModel: VisionViewModel) {
    val state by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    var replacementUri by remember { mutableStateOf<Uri?>(null) }
    var zoom by remember { mutableStateOf(false) }
    var settingsOpen by remember { mutableStateOf(false) }
    var removalConfirmationOpen by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let { if (state.hasTranscript) replacementUri = it else viewModel.selectImage(it) }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        if (saved) cameraUri(context)?.let { if (state.hasTranscript) replacementUri = it else viewModel.selectImage(it) }
    }
    VisionContent(
        state = state,
        onPromptChanged = viewModel::updatePrompt,
        onLibrary = { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        onCamera = { cameraUri(context)?.let(camera::launch) },
        onAsk = viewModel::ask,
        onStop = viewModel::stopGeneration,
        onRetry = viewModel::retryInitialize,
        onRegenerate = viewModel::regenerateLast,
        onZoom = { zoom = true },
        onDownloadModel = viewModel::approveModelDownload,
        onOpenSettings = { settingsOpen = true },
    )
    replacementUri?.let { candidate ->
        AlertDialog(
            onDismissRequest = { replacementUri = null },
            title = { Text("Replace this photo?") },
            text = { Text("The answers for the current photo will be cleared.") },
            confirmButton = { Button(onClick = { viewModel.selectImage(candidate); replacementUri = null }) { Text("Replace") } },
            dismissButton = { Button(onClick = { replacementUri = null }) { Text("Keep current") } },
        )
    }
    if (zoom) state.preview?.let { FullScreenImage(it) { zoom = false } }
    if (settingsOpen) {
        ModelSettingsDialog(
            canRemoveDownloadedModel = state.canRemoveDownloadedModel,
            modelStatus = state.status,
            onRemove = {
                settingsOpen = false
                removalConfirmationOpen = true
            },
            onDismiss = { settingsOpen = false },
        )
    }
    if (removalConfirmationOpen) {
        ModelRemovalConfirmation(
            onRemove = {
                removalConfirmationOpen = false
                viewModel.removeDownloadedModel()
            },
            onDismiss = { removalConfirmationOpen = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VisionContent(
    state: VisionUiState,
    onPromptChanged: (String) -> Unit,
    onLibrary: () -> Unit,
    onCamera: () -> Unit,
    onAsk: (String?) -> Unit,
    onStop: () -> Unit,
    onRetry: () -> Unit,
    onRegenerate: () -> Unit,
    onZoom: () -> Unit,
    onDownloadModel: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
) {
    MaterialTheme {
        Scaffold(
            contentWindowInsets = WindowInsets.safeDrawing,
            topBar = {
                TopAppBar(
                    title = { Text("Ask about a photo") },
                    actions = { TextButton(onClick = onOpenSettings) { Text("Settings") } },
                )
            },
            bottomBar = {
                if (state.status == ModelStatus.READY || state.status == ModelStatus.GENERATING) Composer(state, onPromptChanged, onAsk, onStop)
            },
        ) { padding ->
            when (state.status) {
                ModelStatus.FAILURE -> FailureView(state.message, onRetry, Modifier.padding(padding))
                ModelStatus.AWAITING_CONSENT -> DownloadConsentView(onDownloadModel, Modifier.padding(padding))
                ModelStatus.DOWNLOADING -> DownloadingView(state.message, Modifier.padding(padding))
                ModelStatus.INITIALIZING -> LoadingView(state.message, Modifier.padding(padding))
                ModelStatus.REMOVING -> RemovingModelView(Modifier.padding(padding))
                else -> MainView(state, onLibrary, onCamera, onAsk, onRegenerate, onZoom, Modifier.padding(padding))
            }
        }
    }
}

@Composable private fun DownloadConsentView(download: () -> Unit, modifier: Modifier) = Box(modifier.fillMaxSize(), Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Download the on-device model", style = MaterialTheme.typography.titleMedium)
        Text("The photo model downloads only after you approve it. It stays on this phone.")
        Button(onClick = download) { Text("Download model") }
    }
}

@Composable private fun DownloadingView(message: String, modifier: Modifier) = Box(modifier.fillMaxSize(), Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator()
        Text("Model download in progress", style = MaterialTheme.typography.titleMedium)
        Text(message, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        Text("You can use the model when this download finishes.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable private fun LoadingView(message: String, modifier: Modifier) = Box(modifier.fillMaxSize(), Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator(); Text("Initializing model…", style = MaterialTheme.typography.titleMedium)
        Text(message, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        Text("Preparing the on-device model.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable private fun RemovingModelView(modifier: Modifier) = Box(modifier.fillMaxSize(), Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator()
        Text("Removing downloaded model…", style = MaterialTheme.typography.titleMedium)
    }
}

@Composable private fun FailureView(message: String, retry: () -> Unit, modifier: Modifier) = Box(modifier.fillMaxSize(), Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Model unavailable", style = MaterialTheme.typography.titleLarge); Text(message); Button(onClick = retry) { Text("Try again") }
    }
}

@Composable private fun ModelSettingsDialog(
    canRemoveDownloadedModel: Boolean,
    modelStatus: ModelStatus,
    onRemove: () -> Unit,
    onDismiss: () -> Unit,
) = AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("Settings") },
    text = {
        Text(
            if (canRemoveDownloadedModel) {
                "Remove downloaded model. Downloading it again will require your consent."
            } else if (modelStatus in setOf(ModelStatus.GENERATING, ModelStatus.INITIALIZING, ModelStatus.REMOVING)) {
                "Finish the active response before removing the downloaded model."
            } else {
                "There is no downloaded model to remove."
            },
        )
    },
    confirmButton = {
        Button(onClick = onRemove, enabled = canRemoveDownloadedModel) { Text("Remove downloaded model") }
    },
    dismissButton = { Button(onClick = onDismiss) { Text("Close") } },
)

@Composable private fun ModelRemovalConfirmation(onRemove: () -> Unit, onDismiss: () -> Unit) = AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text("Remove downloaded model?") },
    text = { Text("Only the downloaded model will be removed. Your photos, prompts, and conversations will stay on this phone.") },
    confirmButton = { Button(onClick = onRemove) { Text("Remove model") } },
    dismissButton = { Button(onClick = onDismiss) { Text("Cancel") } },
)

@Composable private fun MainView(state: VisionUiState, library: () -> Unit, camera: () -> Unit, ask: (String?) -> Unit, regenerate: () -> Unit, zoom: () -> Unit, modifier: Modifier) {
    val listState = rememberLazyListState()
    val firstTurnIndex = firstTurnIndex(state.preview != null)
    LaunchedEffect(state.turns.lastOrNull()?.answer, state.turns.size, firstTurnIndex) { if (state.turns.isNotEmpty()) listState.animateScrollToItem(firstTurnIndex + state.turns.lastIndex) }
    LazyColumn(modifier.fillMaxSize().testTag("photo_conversation_list").semantics { contentDescription = "Photo conversation"; liveRegion = LiveRegionMode.Polite }, state = listState, contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp)) {
        item { if (state.preview == null) EmptyPhoto(library, camera, state.imageUpdating || state.status == ModelStatus.GENERATING) else SelectedPhoto(state.preview, library, camera, state.imageUpdating || state.status == ModelStatus.GENERATING, zoom) }
        if (state.preview != null) item { SuggestionRow(state.status == ModelStatus.READY, ask) }
        items(state.turns, key = { it.id }) { TurnBubble(it, state.turns.lastOrNull()?.id == it.id, regenerate) }
    }
}

@Composable private fun EmptyPhoto(library: () -> Unit, camera: () -> Unit, disabled: Boolean) = Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
    Text("Take a photo or choose one from your library."); SourceButtons(library, camera, disabled)
}
@Composable private fun SelectedPhoto(bitmap: Bitmap, library: () -> Unit, camera: () -> Unit, disabled: Boolean, zoom: () -> Unit) = Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Button(onClick = zoom, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) { Image(bitmap.asImageBitmap(), "Selected photo. Double-tap to view full screen.", Modifier.fillMaxWidth().heightIn(max = 220.dp)) }
    Row(verticalAlignment = Alignment.CenterVertically) { SourceButtons(library, camera, disabled); Spacer(Modifier.weight(1f)); Text("Model sees 512 px", style = MaterialTheme.typography.labelSmall) }
}
@Composable private fun SourceButtons(library: () -> Unit, camera: () -> Unit, disabled: Boolean) = Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    Button(onClick = camera, enabled = !disabled) { Text("Camera") }; Button(onClick = library, enabled = !disabled) { Text("Library") }
}
@Composable private fun SuggestionRow(enabled: Boolean, ask: (String?) -> Unit) = Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
    VisionViewModel.suggestions.forEach { Button(onClick = { ask(it) }, enabled = enabled) { Text(it, maxLines = 1) } }
}
@Composable private fun Composer(state: VisionUiState, prompt: (String) -> Unit, ask: (String?) -> Unit, stop: () -> Unit) = Row(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
    OutlinedTextField(value = state.prompt, onValueChange = prompt, modifier = Modifier.weight(1f), label = { Text("Ask about this image") }, enabled = state.preview != null, maxLines = 4)
    Spacer(Modifier.width(8.dp)); if (state.status == ModelStatus.GENERATING) Button(onClick = stop) { Text("Stop") } else Button(onClick = { ask(null) }, enabled = state.canAsk) { Text("Send") }
}
@Composable private fun TurnBubble(turn: VisionTurn, isLast: Boolean, regenerate: () -> Unit) = Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
    val context = LocalContext.current
    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(turn.question, style = MaterialTheme.typography.labelLarge); when { turn.failure != null -> Text(turn.failure); turn.answer.isEmpty() && turn.isStreaming -> Text(if (turn.phase == TurnPhase.READING) "Reading image…" else "Answering…"); else -> Text(turn.answer) }
        turn.performance?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
        if (turn.phase == TurnPhase.FINISHED) Row { Button(onClick = { (context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(ClipData.newPlainText("Answer", turn.answer)) }) { Text("Copy") }; Button(onClick = { context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, turn.answer) }, "Share answer")) }) { Text("Share") }; if (isLast) Button(onClick = regenerate) { Text("Ask again") } }
    }
}
@Composable private fun FullScreenImage(bitmap: Bitmap, close: () -> Unit) {
    var zoomState by remember { mutableStateOf(ZoomState()) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val transform = rememberTransformableState { zoom, pan, _ -> zoomState = zoomState.zoomBy(zoom); offset = if (zoomState.scale == 1f) Offset.Zero else offset + pan }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().safeDrawingPadding().semantics { contentDescription = "Full screen photo. Pinch to zoom. Double-tap to reset." }.pointerInput(Unit) { detectTapGestures(onDoubleTap = { zoomState = zoomState.doubleTap(); if (zoomState.scale == 1f) offset = Offset.Zero }) }, Alignment.Center) {
            Image(bitmap.asImageBitmap(), "Full screen photo", Modifier.fillMaxSize().graphicsLayer(scaleX = zoomState.scale, scaleY = zoomState.scale, translationX = offset.x, translationY = offset.y).transformable(transform))
            Button(onClick = close, modifier = Modifier.align(Alignment.TopEnd).padding(20.dp)) { Text("Close photo") }
        }
    }
}
private fun cameraUri(context: Context): Uri? = runCatching { val dir = File(context.cacheDir, "camera").apply { mkdirs() }; FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", File(dir, "capture.jpg")) }.getOrNull()
internal fun firstTurnIndex(hasPreview: Boolean) = if (hasPreview) 2 else 1
