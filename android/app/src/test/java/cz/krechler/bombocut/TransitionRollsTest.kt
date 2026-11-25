package cz.krechler.bombocut

import cz.krechler.bombocut.engine.CompositionBuilder
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.CutTransition
import cz.krechler.bombocut.model.MotionAnim
import cz.krechler.bombocut.model.Project
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Transitions on two rolls (CompositionBuilder.placeRolls / rollPose): every clip sits where the timeline has
 * it, handles widen the blend window like iOS, and the picture across a transition is the iOS mix even though
 * Media3 always draws roll A over roll B.
 */
class TransitionRollsTest {
    private fun clip(file: String, inP: Double, outP: Double, src: Double, cut: CutTransition? = null) =
        Clip(mediaFile = file, sourceDuration = src, inPoint = inP, outPoint = outP, cut = cut)

    /** What the viewer sees of the incoming clip (0..1) given both rolls' alphas, A drawn over B. */
    private fun incomingShare(inRoll: Int, a: Double, b: Double): Double {
        // over operator: result = A * a + B * b * (1 - a)
        return if (inRoll == 0) a else b * (1 - a)
    }

    @Test fun clipsKeepTheirTimelinePlaces() {
        val p = Project(name = "t", clips = listOf(
            clip("a.mp4", 0.0, 3.0, 3.0),
            clip("b.mp4", 0.5, 3.0, 3.0, CutTransition(MotionAnim.fade, 0.5, handles = false)),
            clip("c.mp4", 0.0, 2.0, 2.0),
            clip("d.mp4", 0.0, 2.0, 2.0, CutTransition(MotionAnim.slideLeft, 0.4, handles = false)),
        ))
        val placed = CompositionBuilder.placeRolls(p)
        val starts = p.clipStarts
        for (q in placed) assertEquals("clip ${q.k} start", starts[q.k], q.start, 1e-9)
        assertEquals(p.duration, placed.last().end, 1e-9)
        // a transition moves to the other roll; no transition: the chain starts again on A
        assertEquals(listOf(0, 1, 0, 1), placed.map { it.roll })
        // the sound crossfades over the window instead of the clip's own fades
        assertEquals(0.5, placed[1].fades.first, 1e-9)
        assertEquals(0.5, placed[0].fades.second, 1e-9)
    }

    @Test fun handlesWidenTheWindow() {
        // both clips have footage past their ends: the transition uses it, the clips don't move
        val p = Project(name = "t", clips = listOf(
            clip("a.mp4", 0.0, 3.0, 5.0),
            clip("b.mp4", 1.0, 4.0, 5.0, CutTransition(MotionAnim.fade, 0.6, handles = true)),
        ))
        val s = p.cutShape(1)
        assertTrue("handles used", s.head > 0 && s.tail > 0)
        val placed = CompositionBuilder.placeRolls(p)
        assertEquals(s.shrink + s.head + s.tail, placed[1].window, 1e-9)
        assertEquals(p.clipStarts[1] - s.head, placed[1].start, 1e-9)
        assertEquals(p.clips[0].duration + s.tail, placed[0].clip.duration, 1e-9)
        assertEquals(p.duration, placed.last().end, 1e-9)
    }

    @Test fun fadeMixesLikeIOSOnBothRolls() {
        val fade = CutTransition(MotionAnim.fade, 0.5, handles = false)
        val p = Project(name = "t", clips = listOf(
            clip("a.mp4", 0.0, 3.0, 3.0), clip("b.mp4", 0.0, 3.0, 3.0, fade), clip("c.mp4", 0.0, 3.0, 3.0, fade),
        ))
        val placed = CompositionBuilder.placeRolls(p)
        for (k in 1..2) {
            val q = placed[k]
            for (f in listOf(0.1, 0.3, 0.5, 0.7, 0.9)) {
                val t = q.start + f * q.window
                val want = fade.poses(f * q.window, q.window).second.opacity
                val a = CompositionBuilder.rollPose(placed, p, 0, t).alpha
                val b = CompositionBuilder.rollPose(placed, p, 1, t).alpha
                // the outgoing clip fills the rest: incoming share + outgoing share = 1
                val got = incomingShare(q.roll, a, b)
                assertEquals("clip $k at $f", want, got, 1e-9)
            }
        }
        // outside transitions only the playing clip's roll shows
        assertEquals(1.0, CompositionBuilder.rollPose(placed, p, 0, 1.0).alpha, 0.0)
        assertEquals(0.0, CompositionBuilder.rollPose(placed, p, 1, 1.0).alpha, 0.0)
        assertEquals(1.0, CompositionBuilder.rollPose(placed, p, 1, placed[1].start + placed[1].window + 0.5).alpha, 0.0)
    }

    @Test fun popComesInOnTop() {
        val pop = CutTransition(MotionAnim.pop, 0.5, handles = false)
        val p = Project(name = "t", clips = listOf(clip("a.mp4", 0.0, 3.0, 3.0), clip("b.mp4", 0.0, 3.0, 3.0, pop)))
        val placed = CompositionBuilder.placeRolls(p)
        // the chain starts on B so the popping clip is on A (drawn on top)
        assertEquals(listOf(1, 0), placed.map { it.roll })
        val q = placed[1]
        val t = q.start + 0.5 * q.window
        val (o, i) = pop.poses(0.5 * q.window, q.window)
        val inc = CompositionBuilder.rollPose(placed, p, 0, t)
        val out = CompositionBuilder.rollPose(placed, p, 1, t)
        assertEquals(i.scale, inc.scale, 1e-9)
        assertEquals(i.opacity, inc.alpha, 1e-9)
        assertEquals(o.scale, out.scale, 1e-9)
        assertEquals(1.0, out.alpha, 1e-9)
    }

    @Test fun slidesMoveBothClips() {
        val slide = CutTransition(MotionAnim.slideLeft, 0.5, handles = false)
        val p = Project(name = "t", clips = listOf(clip("a.mp4", 0.0, 3.0, 3.0), clip("b.mp4", 0.0, 3.0, 3.0, slide)))
        val placed = CompositionBuilder.placeRolls(p)
        val q = placed[1]
        val t = q.start + 0.25 * q.window
        val (o, i) = slide.poses(0.25 * q.window, q.window)
        val inc = CompositionBuilder.rollPose(placed, p, q.roll, t)
        val out = CompositionBuilder.rollPose(placed, p, placed[0].roll, t)
        assertEquals(i.dx, inc.dx, 1e-9); assertEquals(1.0, inc.alpha, 0.0)
        assertEquals(o.dx, out.dx, 1e-9); assertEquals(1.0, out.alpha, 0.0)
    }
}
