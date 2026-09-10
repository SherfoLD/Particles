/// Runtime compilation keeps SwiftPM and Xcode on the identical shader source.
enum ParticleComputeKernels {
    static let threadgroupWidth = 64
    static let contactIterations = 20
    static let neighborCapacity = 48
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Particle { float4 pr; float4 velocity; };
    struct Params {
        float4 bounds; float4 dynamics; uint4 counts; uint4 geometry; float4 limits;
        float4 cursorSegment; float4 cursorMotion; float4 cursorBounds;
    };
    struct Contact { float2 point; float2 normal; };
    constant uint neighborCapacity=\(neighborCapacity);
    constant uint neighborStride=neighborCapacity+1;
    constant uint traversalLimit=512;
    constant uint neighborOverflow=1u<<16, traversalOverflow=1u<<17;
    constant uint compressionDespawn=3, invalidStateDespawn=4, workLimitDespawn=5;
    // velocity.z is compression time; a negative value is a permanent tombstone.
    bool active(Particle a) { return a.velocity.z>=0; }
    bool valid(Particle a) {
        return all(isfinite(a.pr)) && all(isfinite(a.velocity)) && a.pr.z>0 &&
               all(abs(a.pr.xy)<1e8f) && isfinite(dot(a.velocity.xy,a.velocity.xy));
    }
    void despawn(thread Particle &a,device atomic_uint *statistics,constant Params &p,uint reason) {
        a.pr=0; a.velocity=float4(0,0,-1,0);
        if (p.geometry.z & 2u) atomic_fetch_add_explicit(statistics+reason,1u,memory_order_relaxed);
    }
    uint hashCell(int2 cell, uint mask) {
        return ((uint(cell.x) * 73856093u) ^ (uint(cell.y) * 19349663u)) & mask;
    }
    void cursorContact(thread Particle &a, constant Params &p, bool swept) {
        if (p.cursorMotion.z<=0) return; // Uniform branch when disabled.
        float reach=p.cursorMotion.z+a.pr.z;
        float2 center=p.cursorSegment.zw;
        float2 segment=p.cursorSegment.zw-p.cursorSegment.xy;
        if (swept) {
            if (any(a.pr.xy<p.cursorBounds.xy-a.pr.z) || any(a.pr.xy>p.cursorBounds.zw+a.pr.z)) return;
            float t=clamp(dot(a.pr.xy-p.cursorSegment.xy,segment)*p.cursorMotion.w,0.f,1.f);
            center=p.cursorSegment.xy+t*segment;
        } else if (any(abs(a.pr.xy-center)>=reach)) return;
        float2 delta=a.pr.xy-center;
        float distance2=dot(delta,delta);
        if (distance2>=reach*reach) return;
        float distance=sqrt(distance2);
        float2 normal;
        if (distance>.0001f) normal=delta/distance;
        else if (p.cursorMotion.w>0) normal=float2(-segment.y,segment.x)*sqrt(p.cursorMotion.w);
        else normal=float2(0,1);
        float correction=swept ? reach-distance : min(reach-distance,a.pr.z*.5f);
        a.pr.xy+=normal*correction;
        float brushSpeed=swept ? length(p.cursorMotion.xy)*.25f : 0.f;
        float target=max(0.f,dot(p.cursorMotion.xy,normal))+brushSpeed;
        a.velocity.xy+=normal*max(0.f,target-dot(a.velocity.xy,normal));
    }
    kernel void clearGrid(device atomic_int *heads [[buffer(2)]], constant Params &p [[buffer(4)]],
                          device atomic_uint *rebuild [[buffer(13)]],
                          uint i [[thread_position_in_grid]]) {
        if (atomic_load_explicit(rebuild,memory_order_relaxed)!=p.geometry.w) return;
        if (i <= p.counts.y) atomic_store_explicit(heads + i, -1, memory_order_relaxed);
    }
    kernel void integrateParticles(device Particle *state [[buffer(0)]], constant Params &p [[buffer(4)]],
                                   const device float2 *reference [[buffer(12)]],device atomic_uint *rebuild [[buffer(13)]],
                                   device atomic_uint *statistics [[buffer(14)]],
                                   uint i [[thread_position_in_grid]]) {
        if (i >= p.counts.x) return;
        Particle a = state[i];
        if (a.velocity.z==-1) return;
        if (!valid(a)) {
            despawn(a,statistics,p,invalidStateDespawn); state[i]=a;
            atomic_store_explicit(rebuild,p.geometry.w,memory_order_relaxed); return;
        }
        a.velocity.y += p.dynamics.x * p.dynamics.y;
        float speed2 = dot(a.velocity.xy, a.velocity.xy);
        float limit = p.limits.x;
        if (speed2 > limit * limit) a.velocity.xy *= limit * rsqrt(speed2);
        a.pr.xy += a.velocity.xy * p.dynamics.y;
        if (p.limits.w>0) cursorContact(a,p,true);
        if (!valid(a)) {
            despawn(a,statistics,p,invalidStateDespawn); state[i]=a;
            atomic_store_explicit(rebuild,p.geometry.w,memory_order_relaxed); return;
        }
        state[i] = a;
        if (atomic_load_explicit(rebuild,memory_order_relaxed)!=p.geometry.w) {
            float2 delta=a.pr.xy-reference[i];
            if (dot(delta,delta)>=p.dynamics.w*p.dynamics.w*.249f)
                atomic_store_explicit(rebuild,p.geometry.w,memory_order_relaxed);
        }
    }
    kernel void buildGrid(const device Particle *state [[buffer(0)]], device atomic_int *heads [[buffer(2)]],
                          device int4 *links [[buffer(3)]], constant Params &p [[buffer(4)]],
                          device atomic_uint *rebuild [[buffer(13)]],
                          uint i [[thread_position_in_grid]]) {
        if (i >= p.counts.x || atomic_load_explicit(rebuild,memory_order_relaxed)!=p.geometry.w || !active(state[i])) return;
        int2 cell = int2(floor(state[i].pr.xy * p.dynamics.z));
        int next=atomic_exchange_explicit(heads + hashCell(cell, p.counts.y), int(i), memory_order_relaxed);
        links[i] = int4(next,cell,0);
    }
    kernel void cacheNeighbors(const device Particle *state [[buffer(0)]],device atomic_int *heads [[buffer(2)]],
                               const device int4 *links [[buffer(3)]],constant Params &p [[buffer(4)]],
                               device uint *neighbors [[buffer(11)]],device float2 *reference [[buffer(12)]],
                               device atomic_uint *rebuild [[buffer(13)]],
                               device atomic_uint *statistics [[buffer(14)]],
                               uint i [[thread_position_in_grid]]) {
        if (i>=p.counts.x || atomic_load_explicit(rebuild,memory_order_relaxed)!=p.geometry.w) return;
        if ((p.geometry.z & 2u) && i==0) atomic_fetch_add_explicit(statistics,1u,memory_order_relaxed);
        Particle a=state[i];
        if (!active(a)) { neighbors[i*neighborStride]=0; return; }
        int2 cell=links[i].yz; uint count=0, visits=0;
        // Both real crowding and hash collisions have a strict work budget.
        // Saturated lists still supply a bounded set of contacts for recovery.
        for (int y=-1;y<=1 && count<=neighborCapacity && visits<traversalLimit;y++)
        for (int x=-1;x<=1 && count<=neighborCapacity && visits<traversalLimit;x++) {
            int2 neighbor=cell+int2(x,y);
            int j=atomic_load_explicit(heads+hashCell(neighbor,p.counts.y),memory_order_relaxed);
            while (j>=0 && count<=neighborCapacity && visits<traversalLimit) {
                visits++;
                int4 entry=links[j];
                if (uint(j)!=i && all(entry.yz==neighbor)) {
                    Particle b=state[j]; float2 delta=b.pr.xy-a.pr.xy;
                    float reach=a.pr.z+b.pr.z+p.dynamics.w;
                    if (dot(delta,delta)<=reach*reach) {
                        if (count<neighborCapacity) neighbors[i*neighborStride+1+count]=uint(j);
                        count++;
                    }
                }
                j=entry.x;
            }
        }
        uint overflow=count>neighborCapacity ? neighborOverflow : (visits>=traversalLimit ? traversalOverflow : 0u);
        neighbors[i*neighborStride]=min(count,neighborCapacity) | overflow;
        reference[i]=a.pr.xy;
        if (p.geometry.z & 2u) {
            if (count>neighborCapacity) atomic_fetch_add_explicit(statistics+1,1u,memory_order_relaxed);
            atomic_fetch_max_explicit(statistics+2,count,memory_order_relaxed);
        }
    }
    void reflect(thread Particle &a, float2 normal, bool bounce) {
        float speed = dot(a.velocity.xy, normal);
        if (speed >= 0) return;
        float restitution = bounce && speed < -45 ? .42f : 0;
        a.velocity.xy -= normal * ((1 + restitution) * speed);
        float2 tangent = float2(-normal.y, normal.x);
        float tangentSpeed = dot(a.velocity.xy, tangent);
        a.velocity.xy -= tangent * clamp(tangentSpeed, speed * .22f, -speed * .22f);
    }
    bool fits(float2 point, float r, constant Params &p) {
        return point.x >= p.bounds.x + r && point.x <= p.bounds.z - r && point.y >= p.bounds.y + r;
    }
    void walls(thread Particle &a, constant Params &p, bool bounce) {
        float r = a.pr.z;
        if (a.pr.x < p.bounds.x + r) { a.pr.x = p.bounds.x + r; reflect(a, float2(1,0), bounce); }
        if (a.pr.x > p.bounds.z - r) { a.pr.x = p.bounds.z - r; reflect(a, float2(-1,0), bounce); }
        if (a.pr.y < p.bounds.y + r) { a.pr.y = p.bounds.y + r; reflect(a, float2(0,1), bounce); }
    }
    void rectangle(thread Particle &a, float4 rect, constant Params &p, bool bounce) {
        float2 q = clamp(a.pr.xy, rect.xy, rect.zw), d = a.pr.xy - q;
        float d2 = dot(d,d), r = a.pr.z;
        if (d2 >= r*r) return;
        if (d2 > .00001f) {
            float2 n = d * rsqrt(d2), exit = q + n * r;
            if (fits(exit, r, p)) { a.pr.xy = exit; reflect(a,n,bounce); return; }
        }
        float2 exits[4] = {float2(a.pr.x, rect.w+r), float2(rect.z+r,a.pr.y),
                           float2(rect.x-r,a.pr.y), float2(a.pr.x,rect.y-r)};
        float2 normals[4] = {float2(0,1),float2(1,0),float2(-1,0),float2(0,-1)};
        float best = INFINITY; int choice = -1;
        for (int k=0;k<4;k++) {
            float2 travel = exits[k] - a.pr.xy;
            float dist = dot(travel,travel);
            if (dist < best && fits(exits[k],r,p)) { best=dist; choice=k; }
        }
        if (choice >= 0) { a.pr.xy=exits[choice]; reflect(a,normals[choice],bounce); }
    }
    void polygon(thread Particle &a, float4 bounds, uint start, uint count,
                 const device float4 *edges, constant Params &p, bool bounce) {
        float2 point=a.pr.xy; float r=a.pr.z;
        if (any(point <= bounds.xy-r) || any(point >= bounds.zw+r)) return;
        bool inside=false;
        for (uint i=0;i<count;i++) {
            float4 e=edges[(start+i)*2];
            if ((e.y>point.y) != (e.y+e.w>point.y) && point.x < e.x+(point.y-e.y)*e.z/e.w) inside=!inside;
        }
        float best=INFINITY; Contact contact; bool found=false;
        for (uint i=0;i<count;i++) {
            float4 e=edges[(start+i)*2], v=edges[(start+i)*2+1];
            float t=clamp(dot(point-e.xy,e.zw)*v.x,0.f,1.f);
            float2 q=e.xy+t*e.zw, d=point-q;
            float d2=dot(d,d);
            if (!inside && d2>=r*r) continue;
            float2 n=inside || d2<1e-10f ? v.yz : d*rsqrt(d2);
            float2 exit=q+n*(r+.001f);
            if (!fits(exit,r,p)) continue;
            float2 travel=exit-point;
            float dist=inside ? dot(travel,travel) : d2;
            if (dist<best) { best=dist; contact={exit,n}; found=true; }
        }
        if (found) { a.pr.xy=contact.point; reflect(a,contact.normal,bounce); }
    }
    // Same sampled native continuous corner as RoundedWindowCollider. Most
    // contacts are on straight edges and never touch the curve table.
    float3 cornerDistance(float2 q, float2 profile, const device float4 *curve, uint count) {
        if (q.x>=profile.y || q.y>=profile.y)
            return q.x<q.y ? float3(-q.x,-1,0) : float3(-q.y,0,-1);
        if (profile.x==0) { float d=length(q); return float3(d,q/d); }
        q/=profile.x;
        float best=INFINITY; float2 bestD=0, bestN=0; bool outside=false;
        for (uint i=0;i<count;i++) {
            float4 e=curve[2*i], v=curve[2*i+1];
            float2 delta=q-e.xy;
            if (dot(v.yz,delta)>0) outside=true;
            float t=clamp(dot(delta,e.zw)*v.x,0.f,1.f);
            float2 d=delta-t*e.zw; float d2=dot(d,d);
            if (d2<best) { best=d2; bestD=d; bestN=v.yz; }
        }
        float d=sqrt(best);
        if (outside && d>1e-10f) return float3(d*profile.x,bestD/d);
        return float3(-d*profile.x,bestN);
    }
    bool containsWindow(float2 point,float r,float4 rect,float2 profile,
                        const device float4 *curve,uint count) {
        float2 q=rect.zw-abs(point-rect.xy);
        if (any(q<=-r)) return false;
        if (q.x>=profile.y || q.y>=profile.y) return true;
        return cornerDistance(q,profile,curve,count).x<r;
    }
    Contact nearestWindow(float2 point,float r,float4 rect,float2 profile,
                          const device float4 *curve,uint count) {
        float2 delta=point-rect.xy;
        float3 d=cornerDistance(rect.zw-abs(delta),profile,curve,count);
        float2 normal=-d.yz*select(float2(1),float2(-1),delta<0);
        return {point+(r-d.x)*normal,normal};
    }
    bool validWindowExit(float2 point,float r,const device float4 *windows,
                         const device float4 *curve,constant Params &p) {
        if (!fits(point,r,p)) return false;
        for (uint j=0;j<p.geometry.x;j++)
            if (containsWindow(point,r,windows[2*j],windows[2*j+1].xy,curve,p.geometry.y)) return false;
        return true;
    }
    bool confinedByWindows(float2 point,float r,const device float4 *windows,
                           const device float4 *curve,constant Params &p) {
        // Overlap is pressure only with opposing nearby constraints. A pile
        // on a moving window has open space above it; a closing chamber does
        // not. Probe a bounded neighborhood, including the desktop walls.
        float reach=32.f*r;
        return (!validWindowExit(point+float2(0,reach),r,windows,curve,p) &&
                !validWindowExit(point-float2(0,reach),r,windows,curve,p)) ||
               (!validWindowExit(point+float2(reach,0),r,windows,curve,p) &&
                !validWindowExit(point-float2(reach,0),r,windows,curve,p));
    }
    bool windowUnion(thread Particle &a,const device float4 *windows,const device float4 *curve,
                     const device float4 *exits,constant Params &p,bool bounce) {
        float2 origin=a.pr.xy; float r=a.pr.z, clearance=r+.001f;
        int first=-1;
        for (uint j=0;j<p.geometry.x;j++) {
            if (containsWindow(origin,r,windows[2*j],windows[2*j+1].xy,curve,p.geometry.y)) { first=int(j); break; }
        }
        if (first<0) return true;
        Contact nearest=nearestWindow(origin,clearance,windows[2*first],windows[2*first+1].xy,curve,p.geometry.y);
        if (validWindowExit(nearest.point,r,windows,curve,p)) {
            // A sampled window can sweep through many rows in one update.
            // Reflect deep penetration into free space instead of flattening
            // every row onto the same edge and manufacturing lasting pressure.
            float2 travel=nearest.point-origin;
            float2 reflected=nearest.point+travel;
            if (dot(travel,travel)>r*r*.25f && validWindowExit(reflected,r,windows,curve,p))
                nearest.point=reflected;
            a.pr.xy=nearest.point; reflect(a,nearest.normal,bounce); return true;
        }
        float4 header=exits[uint(a.velocity.w)];
        float best=INFINITY; Contact contact=nearest;
        for (uint j=0;j<uint(header.y);j++) {
            float4 edge=exits[uint(header.x)+2*j];
            float t=clamp(dot(origin-edge.xy,edge.zw)/dot(edge.zw,edge.zw),0.f,1.f);
            float2 point=edge.xy+t*edge.zw, delta=point-origin;
            float d=dot(delta,delta);
            if (d<best) { best=d; contact={point,exits[uint(header.x)+2*j+1].xy}; }
        }
        // A blocked nearest exit can mean a closing gap. Do not teleport a
        // trapped ball through the window union to a distant exposed edge.
        // A valid nearest exit above is ordinary obstacle motion, however far
        // the window travelled between geometry samples; it is not crushing.
        if (best<=64.f*r*r) { a.pr.xy=contact.point; reflect(a,contact.normal,bounce); return true; }
        return false;
    }
    void pairContact(Particle a,Particle b,uint i,uint j,bool bounce,
                     thread float2 &correction,thread float2 &velocityDelta,
                     thread float &contactWeight,thread float &penetration) {
        if (!active(b)) return;
        float2 d=b.pr.xy-a.pr.xy; float d2=dot(d,d), diameter=a.pr.z+b.pr.z;
        if (d2>=diameter*diameter) return;
        float distance=sqrt(d2);
        float2 n;
        if (distance>.0001f) {
            n=d/distance;
        } else {
            // Window projection can put many particles at the same point.
            // Break that symmetry in both dimensions, with opposite normals
            // for the two owners of a pair (no preferred horizontal row).
            uint hash=min(i,j)*0x9e3779b9u ^ max(i,j)*0x85ebca6bu;
            hash ^= hash>>16; hash *= 0x7feb352du; hash ^= hash>>15;
            float2 direction=float2(float(hash & 65535u)-32767.5f,
                                    float(hash>>16)-32767.5f);
            n=normalize(direction)*(i<j ? 1.f : -1.f);
        }
        float weight=b.pr.z*b.pr.z/(a.pr.z*a.pr.z+b.pr.z*b.pr.z);
        contactWeight+=weight;
        penetration=max(penetration,(diameter-distance)/diameter);
        correction-=n*(max(0.f,diameter-distance-.005f)*.85f*weight);
        float2 v=b.velocity.xy-a.velocity.xy; float speed=dot(v,n);
        if (speed<0) {
            float impulse=-(1+(bounce && speed < -45 ? .48f : 0.f))*speed;
            float2 tangent=float2(-n.y,n.x);
            float friction=clamp(-dot(v,tangent),-.22f*impulse,.22f*impulse);
            velocityDelta-=(n*impulse+tangent*friction)*weight;
        }
    }
    kernel void solveContacts(const device Particle *input [[buffer(0)]],device Particle *output [[buffer(1)]],
                              constant Params &p [[buffer(4)]],
                              const device float4 *shapes [[buffer(5)]],const device float4 *edges [[buffer(6)]],
                              const device float4 *windows [[buffer(7)]],const device float4 *curve [[buffer(8)]],
                              const device float4 *rects [[buffer(9)]],const device float4 *exits [[buffer(10)]],
                              const device uint *neighbors [[buffer(11)]],
                              const device float2 *reference [[buffer(12)]],device atomic_uint *rebuild [[buffer(13)]],
                              device atomic_uint *statistics [[buffer(14)]],
                              uint i [[thread_position_in_grid]]) {
        if (i>=p.counts.x) return;
        Particle a=input[i]; float2 correction=0, velocityDelta=0;
        if (!active(a)) { output[i]=a; return; }
        bool bounce=(p.geometry.z & 1u)!=0;
        uint cached=neighbors[i*neighborStride], count=cached & 65535u;
        bool saturated=(cached & (neighborOverflow | traversalOverflow))!=0;
        float contactWeight=0, penetration=0;
        for (uint k=0;k<count;k++) {
            uint j=neighbors[i*neighborStride+1+k];
            pairContact(a,input[j],i,j,bounce,correction,velocityDelta,contactWeight,penetration);
        }
        // Jacobi: each thread owns one output, never races its neighbors.
        // Normalize simultaneous impulses: an interior ball must not receive
        // several full responses computed from the same old velocity.
        float relaxation=1.f/max(1.f,contactWeight);
        correction*=relaxation;
        velocityDelta*=relaxation;
        // Bound positional motion through transient overlaps from moved windows.
        float correction2=dot(correction,correction);
        float limit=a.pr.z*.5f;
        if (correction2>limit*limit) correction*=limit*rsqrt(correction2);
        a.pr.xy+=correction;
        // Feed separation back into velocity so gravity cannot keep driving a
        // supported ball into its neighbors while position projection holds it.
        a.velocity.xy+=velocityDelta+correction/p.dynamics.y;
        cursorContact(a,p,false);
        walls(a,p,bounce);
        for (uint j=0;j<p.counts.w;j++) polygon(a,shapes[2*j],uint(shapes[2*j+1].x),uint(shapes[2*j+1].y),edges,p,bounce);
        for (uint j=0;j<p.counts.z;j++) rectangle(a,rects[j],p,bounce);
        bool escaped=windowUnion(a,windows,curve,exits,p,bounce);
        // Pair overlap alone cannot distinguish impact from confinement.
        // Require opposing geometry for overlap-based pressure. Saturated
        // caches also get a bounded recovery interval before retirement.
        float dt=p.limits.y;
        bool compressed=penetration>.45f && confinedByWindows(a.pr.xy,a.pr.z,windows,curve,p);
        a.velocity.z=saturated || compressed ? a.velocity.z+dt : 0.f;
        if (!valid(a)) despawn(a,statistics,p,invalidStateDespawn);
        else if (!escaped || a.velocity.z>=.1f)
            despawn(a,statistics,p,escaped && (cached & traversalOverflow)!=0 ? workLimitDespawn : compressionDespawn);
        else {
            float speed2=dot(a.velocity.xy,a.velocity.xy), limit=p.limits.x;
            if (speed2>limit*limit) a.velocity.xy*=limit*rsqrt(speed2);
        }
        output[i]=a;
        // Fused displacement reduction schedules the next iteration's rebuild.
        // The list's skin covers both particles until either moves half of it.
        float2 delta=a.pr.xy-reference[i];
        if (!active(a) || dot(delta,delta)>=p.dynamics.w*p.dynamics.w*.249f)
            atomic_store_explicit(rebuild,p.geometry.w+1u,memory_order_relaxed);
    }
    """
}
