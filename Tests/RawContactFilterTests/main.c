#include "RawContactFilter.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void contact(uint8_t *c, int x, int y, unsigned id, unsigned state) {
    unsigned rx = (unsigned)x & 8191, ry = (unsigned)y & 8191;
    memset(c, 0, 9);
    c[0]=rx; c[1]=((rx>>8)&31)|((ry&7)<<5); c[2]=ry>>3;
    c[3]=((ry>>11)&3)|(state<<5); c[4]=25; c[5]=20; c[6]=40; c[7]=30; c[8]=id;
}
static TERawFilter configured(void) {
    return (TERawFilter){.left=.1,.right=.1,.top=.1,.bottom=.1,
        .min_x=-7356,.min_y=-174,.max_x=7869,.max_y=9956};
}
int main(void) {
    TERawFilter f=configured(); uint8_t in[22]={0x31,0x98,0x12,0x34}, out[64], saved[22]; size_t n=0;
    contact(in+4, 100, 0, 1, 4); contact(in+13, -3500, 0, 2, 4); memcpy(saved,in,22);
    assert(te_filter_packet(&f,in,22,out,64,&n) && n==13);
    assert(!memcmp(in,saved,22) && !memcmp(out,in,4));
    assert((out[12]&15)==1 && (out[7]>>5)==3 && f.removed_contacts==1);
    assert(te_filter_packet(&f,in,22,out,64,&n) && (out[7]>>5)==4);
    // Each independent edge, including two simultaneous excluded contacts.
    const int xy[][2]={{-3500,0},{3800,0},{100,-2500},{100,2400}};
    for (int i=0;i<4;i++) {
        f=configured(); contact(in+4,xy[i][0],xy[i][1],1,4); contact(in+13,xy[i][0],xy[i][1],2,4);
        assert(te_filter_packet(&f,in,22,out,64,&n) && n==4 && !f.admitted);
    }
    // Crossing removes the contact; reentry uses make-touch to reset native history.
    f=configured(); contact(in+4,100,0,1,4);
    assert(te_filter_packet(&f,in,13,out,64,&n) && n==13);
    contact(in+4,-3500,0,1,4); assert(te_filter_packet(&f,in,13,out,64,&n) && n==4);
    contact(in+4,100,0,1,4); assert(te_filter_packet(&f,in,13,out,64,&n) && (out[7]>>5)==3);
    // Edge click does not begin a click when a held press slides into the center.
    f=configured(); contact(in+4,-3500,0,1,4); in[1]=0x9f;
    assert(te_filter_packet(&f,in,13,out,64,&n) && out[1]==0x98);
    contact(in+4,100,0,1,4); assert(te_filter_packet(&f,in,13,out,64,&n) && !(out[1]&3));
    in[1]=0x98; assert(te_filter_packet(&f,in,13,out,64,&n));
    in[1]=0x9d; assert(te_filter_packet(&f,in,13,out,64,&n) && (out[1]&7)==5);
    contact(in+4,-3500,0,1,4); assert(te_filter_packet(&f,in,13,out,64,&n) && (out[1]&3)==1);
    in[1]=0x98; assert(te_filter_packet(&f,in,13,out,64,&n) && !(out[1]&7));
    // Already admitted liftoff is preserved even outside the boundary.
    contact(in+4,100,0,1,4); assert(te_filter_packet(&f,in,13,out,64,&n));
    contact(in+4,-3500,0,1,5); assert(te_filter_packet(&f,in,13,out,64,&n) && n==13 && !(f.admitted&2));
    // Malformed, oversized, duplicate-ID, and invalid-configuration packets fail.
    assert(!te_filter_packet(&f,in,12,out,64,&n));
    contact(in+4,100,0,1,4); contact(in+13,200,0,1,4);
    TERawFilter before=f; assert(!te_filter_packet(&f,in,22,out,64,&n) && !memcmp(&before,&f,sizeof f));
    assert(!te_filter_packet(&f,in,22,out,12,&n));
    f.left=.5; assert(!te_filter_packet(&f,in,13,out,64,&n));
    // Palm rule: off by default, then a large center contact is dropped.
    f=configured(); contact(in+4,100,0,1,4); in[8]=250;
    assert(te_filter_packet(&f,in,13,out,64,&n) && n==13); // max_major == 0: rule off
    f=configured(); f.max_major=150; contact(in+4,100,0,1,4); contact(in+13,300,0,2,4); in[8]=60; in[17]=250;
    assert(te_filter_packet(&f,in,22,out,64,&n) && n==13 && (out[12]&15)==1 && f.palm==4); // palm id 2 only
    assert(f.removed_contacts==1 && (f.admitted&4)==0);
    // Sticky: it stays rejected after it shrinks, until it lifts.
    in[17]=40; assert(te_filter_packet(&f,in,22,out,64,&n) && n==13 && f.palm==4);
    contact(in+13,300,0,2,5); in[17]=40; assert(te_filter_packet(&f,in,22,out,64,&n) && n==13 && !f.palm);
    contact(in+13,300,0,2,4); in[17]=40; assert(te_filter_packet(&f,in,22,out,64,&n) && n==22); // same id is a new touch
    // Below the limit passes untouched; a palm-only frame is empty and cannot click.
    f=configured(); f.max_major=150; contact(in+4,100,0,1,4); in[8]=149;
    assert(te_filter_packet(&f,in,13,out,64,&n) && n==13 && !f.palm);
    f=configured(); f.max_major=150; contact(in+4,100,0,1,4); in[8]=150; in[1]=0x9d;
    assert(te_filter_packet(&f,in,13,out,64,&n) && n==4 && !(out[1]&7) && f.blocked_clicks==1);
    // A rejected frame leaves the palm state untouched.
    f=configured(); f.max_major=150; f.palm=2; contact(in+4,100,0,1,4); contact(in+13,200,0,1,4); in[8]=250; in[17]=250;
    before=f; assert(!te_filter_packet(&f,in,22,out,64,&n) && !memcmp(&before,&f,sizeof f));
    uint8_t control[]={0x40,15,0}; f=configured();
    assert(te_filter_packet(&f,control,3,out,64,&n) && n==3 && !memcmp(out,control,3));
    puts("Raw packet checks passed: mixed contacts, four edges, reentry, clicks/releases, liftoff, palm rule, malformed packets, control reports.");
}
