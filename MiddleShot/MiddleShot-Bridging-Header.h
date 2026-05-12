#ifndef MiddleShot_Bridging_Header_h
#define MiddleShot_Bridging_Header_h

#import <CoreFoundation/CoreFoundation.h>
#import <stdbool.h>

// MultitouchSupport.framework — private. Layout derived from community headers;
// verify on every macOS major release. See MagicMouseListener.swift for the
// compatibility note.

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTReadout;

typedef struct {
    int frame;
    double timestamp;
    int pathIndex;
    int state;        // 1..3 approaching, 4 touching, 5..7 leaving
    int fingerId;
    int handId;
    MTReadout normalized;
    float size;
    int unknown2;
    float angle;
    float majorAxis;
    float minorAxis;
    MTReadout absolute;
    int unknown3[2];
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device,
                                         MTTouch *touches,
                                         int touchCount,
                                         double timestamp,
                                         int frame);

CFArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTUnregisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTDeviceStart(MTDeviceRef device, int runMode);
void MTDeviceStop(MTDeviceRef device);
bool MTDeviceIsBuiltIn(MTDeviceRef device);

#endif
