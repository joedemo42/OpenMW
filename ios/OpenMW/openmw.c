/* The app is SDL2main (main(), UIKit app delegate) + OpenMW (SDL_main() in libopenmw.a, see OTHER_LDFLAGS).
   Xcode links no binary for a target without compiled sources, hence this file. */
extern int SDL_main(int argc, char* argv[]);
