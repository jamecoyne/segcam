// Syphon's umbrella header leaves out SyphonSubclassing.h, and that category is where
// -[SyphonClientBase newSurface] lives — the one call that hands over the shared IOSurface.
// Importing both here (rather than editing the framework, which would break its signature)
// is what makes the surface reachable from Swift.
#import <Syphon/Syphon.h>
#import <Syphon/SyphonSubclassing.h>
