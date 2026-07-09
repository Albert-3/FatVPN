import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Animated startup splash shown while the session is still initializing.
///
/// Picks up seamlessly from the native launch screen (same dark background +
/// centered logo, see `android/.../launch_background.xml`): the logo fades and
/// scales in over a soft pulsing accent glow, with a subtle progress shimmer at
/// the bottom. Purely decorative — it holds the frame until `AuthController`
/// resolves the stored session.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Entrance: logo fade + scale, plays once.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  // Ambient: the accent glow behind the logo breathes forever.
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  late final Animation<double> _fade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
  );

  late final Animation<double> _scale = Tween<double>(begin: 0.82, end: 1.0)
      .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutBack));

  @override
  void dispose() {
    _entrance.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Spacer(flex: 5),
            FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: _scale,
                child: AnimatedBuilder(
                  animation: _glow,
                  builder: (context, child) {
                    // Breathing glow: opacity + blur radius track the pulse.
                    final t = Curves.easeInOut.transform(_glow.value);
                    return Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent
                                .withValues(alpha: 0.18 + 0.22 * t),
                            blurRadius: 32 + 28 * t,
                            spreadRadius: 4 + 8 * t,
                          ),
                        ],
                      ),
                      child: child,
                    );
                  },
                  child: Image.asset('assets/images/logo.png', height: 96),
                ),
              ),
            ),
            const Spacer(flex: 4),
            FadeTransition(
              opacity: _fade,
              child: const _PulsingDots(),
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

/// Three accent dots that fill in sequence — a lightweight, on-brand
/// replacement for the default CircularProgressIndicator.
class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot is a phase-shifted sine wave, giving a wave effect.
            final phase = (_controller.value + i * 0.2) % 1.0;
            final t = (math.sin(phase * 2 * math.pi) + 1) / 2;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.lerp(
                    AppColors.disabled,
                    AppColors.accent,
                    t,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
