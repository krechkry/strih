package cz.krechler.bombocut

import cz.krechler.bombocut.engine.CompositionBuilder
import cz.krechler.bombocut.model.AnimPair
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.ClipTransform
import cz.krechler.bombocut.model.MotionAnim
import cz.krechler.bombocut.model.Overlay
import cz.krechler.bombocut.model.OverlayKind
import cz.krechler.bombocut.model.Project
import org.junit.Assert.assertEquals
import org.junit.Test

/** Video layers in the compositor: which ones play, in which order, and where they are at each moment. */
class VideoLayerTest {
    private fun layer(start: Double, dur: Double, tr: ClipTransform = ClipTransform(), anim: AnimPair = AnimPair()) =
        Overlay(kind = OverlayKind.Video("v.mp4", 10.0, 1.0), start = start, duration = dur, transform = tr, anim = anim)

    @Test fun orderAndTime() {
        val a = layer(0.5, 1.0); val b = layer(1.0, 1.0)
        val past = layer(9.0, 1.0)  // starts after the clips end: not played
        val text = Overlay(kind = OverlayKind.Text("hi"))
        val p = Project(name = "t", clips = listOf(Clip(mediaFile = "c.mp4", sourceDuration = 4.0)), overlays = listOf(a, text, b, past))
        // the last in the list is drawn on top, so it comes first
        assertEquals(listOf(b.id, a.id), CompositionBuilder.videoLayers(p).map { it.id })
        assertEquals(0.0, CompositionBuilder.layerPose(a, 0.4).alpha, 0.0)
        assertEquals(1.0, CompositionBuilder.layerPose(a, 0.9).alpha, 0.0)
        assertEquals(0.0, CompositionBuilder.layerPose(a, 1.5).alpha, 0.0)
        assertEquals(true, CompositionBuilder.blends(p))
    }

    @Test fun placementAndFadeIn() {
        val o = layer(1.0, 2.0, ClipTransform(x = 0.2, y = -0.1, scale = 0.5, rotation = 0.3), AnimPair(inAnim = MotionAnim.fade, inDur = 0.4))
        val mid = CompositionBuilder.layerPose(o, 2.0)
        assertEquals(0.2, mid.dx, 1e-9); assertEquals(-0.1, mid.dy, 1e-9)
        assertEquals(0.5, mid.scale, 1e-9); assertEquals(0.3, mid.rotation, 1e-9); assertEquals(1.0, mid.alpha, 1e-9)
        val fading = CompositionBuilder.layerPose(o, 1.1)
        val want = o.anim.pose(0.1, 2.0).opacity
        assertEquals(want, fading.alpha, 1e-9)
        assert(fading.alpha in 0.01..0.99)
    }
}
