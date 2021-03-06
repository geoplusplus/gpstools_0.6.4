function [abort,msg,stats]=gt_obsedit(td,time,prm)
%-------------------------------------------------------------------------------
% [system] : GpsTools
% [module] : observation data editor
% [func]   : detect/repair cycle-slip, smooth codes and generate clean obs. data
% [argin]  : td,time = date(mjd-gpst),time vector(sec)
%            prm     = processing parameters struct (see prm_gpsest_def.m)
% [argout] : abort   = abort status (1:abort,0:completed,-1:error)
%            msg     = error message
%            stats   = processing statistics
% [note]   :
% [version]: $Revision: 20 $ $Date: 2009-05-01 04:15:33 +0900 (金, 01 5 2009) $
%            Copyright(c) 2004-2006 by T.Takasu, all rights reserved
% [history]: 04/06/03  0.1  new
%            06/03/26  0.11 restructured
%            06/06/24  0.12 add argout msg
%            06/12/19  0.13 fix bug on saving slip infomation (gt_0.6.3p3a)
%            06/12/20  0.14 fix bug on saving slip infomation if no slip exists (gt_0.6.3p3a)
%            06/12/22  0.15 fix bug on error stop on accessing rstat (gt_0.6.3p3b)
%            08/11/21  0.16 support no trops delay correction option (gt_0.6.4)
%                           support phase-adjustment to repair clock-jump
%                           support exclusion of unhealthy satellites
%                           support smoothed-iono-free-code option
%                           add trcv in index(:,5) of clean observation data
%-------------------------------------------------------------------------------
abort=0; msg=''; stats=[];

[nav,inav]=readnav(td,time,prm.sats,prm.rcvs,prm.dirs.nav,prm.src.nav);
if isempty(nav)
    gt_log('no navigation message   : dir=%s src=%s',prm.dirs.nav,prm.src.nav);
    abort=-1; msg='no navigation message'; return;
end
if prm.obs.separc, ecls=eclipsep(td,time,nav,inav,prm); else ecls=[]; end

for n=1:length(prm.rcvs)
    if gmsg('reading raw obs data : %s %s',pstr(td,time),prm.rcvs{n})
        abort=1; break
    end
    % read raw observation data
    [z,iz,rpos,adel,atype,rtype]=readobs(td,time,prm.sats,prm.rcvs{n},...
                                         prm.dirs.obs,prm.obs.src,{},inf);
    if isempty(z)
        gt_log('no raw obs data         : %s dir=%s src=%s',prm.rcvs{n},...
               prm.dirs.obs,prm.obs.src);
    else
        if gmsg('editing obs data : %s %s',pstr(td,time),prm.rcvs{n})
            abort=1; break;
        end
        % generate clean observation data
        [z,iz,arc,rstat,azel,slip,ss]=cleanobs(td,time,z,iz,prm.rcvs{n},rpos,...
                                               nav,inav,ecls,prm);
        stats=[stats;ss];
        
        % save clean observation data
        saveobs(td,time,prm.rcvs{n},z,iz,arc,rstat,azel,slip,rpos,adel,...
                atype{1},rtype{1},prm);
        
        if isempty(z)
            gt_log('no valid obs data       : %s dir=%s src=%s',prm.rcvs{n},...
                   prm.dirs.obs,prm.obs.src);
        end
    end
end

% generate clean obs data ------------------------------------------------------
function [zc,izc,arc,rstat,azelc,slip,stats]=cleanobs(td,time,z,iz,rcv,rpos,...
                                                      nav,inav,ecls,prm)
zc=[]; izc=[]; arc=[]; rstat={}; azelc=[]; slip=[];
stats.loge={}; stats.logs={}; stats.logc={}; s=zeros(length(prm.sats),1);
stats.tobs=s; stats.ndat=s; stats.nobs=s; stats.noutl=s; stats.nslip=s;
stats.narc=s; stats.mp1=s; stats.mp2=s;
if isempty(z), return; end

% screen by time range
i=find(time(1)-1<=iz(:,1)&iz(:,1)<time(end)+1); z=z(i,:); iz=iz(i,:);
for n=1:length(prm.sats), stats.tobs(n)=sum(iz(:,2)==n); end

% estimate receiver state/satellite direction
[trcv,rstat,azel]=rcvstate(td,z,iz,prm.sats,rcv,nav,inav,rpos,prm);

% screen by elevation angle
if prm.obs.elmin>0
    i=find(azel(:,2)>prm.obs.elmin);
    z=z(i,:); iz=iz(i,:); trcv=trcv(i); azel=azel(i,:);
end
% repair clock-jump of steered-clock receiver
if prm.obs.clkrep
    [z,iz,rstat,stats.logc]=fixclkjump(td,z,iz,rcv,rstat,prm);
end
for n=1:length(prm.sats)
    i=find(iz(:,2)==n);
    if ~isempty(i)
        zi=z(i,:); izi=iz(i,:); tt=trcv(i); azelz=azel(i,:);
        
        % detect/repair cycle-slips and extract arcs
        [t,zi,arcn,i,sl,ol,log1,log2]=...
            editobs(td,izi(:,1),zi,azelz,prm.sats{n},rcv,prm.obs,prm.f1,prm.f2);
        tt=tt(i);
        
        stats.ndat(n)=size(zi,1);
        stats.nslip(n)=size(sl,1);
        stats.noutl(n)=size(ol,1);
        stats.loge={stats.loge{:},log1{:}};
        stats.logs={stats.logs{:},log2{:}};
        if ~isempty(sl), sl=sl(:,[1,1,2]); sl(:,2)=n; slip=[slip;sl]; end
        
        % separate arc at eclipse boundary
        if prm.obs.separc, arcn=separc(time,tt,arcn,ecls(n,:),prm); end
        
        % generate smoothed codes
        [zi,arcn,stats.mp1(n),stats.mp2(n)]=smoothcode(tt,zi,arcn,prm);
        
        for a=arcn'
            j=a(1):a(2);
            
            % extract data by time
            j=j(time(1)<=tt(j)&tt(j)<=time(end)&mod(tt(j)-time(1),prm.tint)==0);
            
            % screen min points of arc
            if length(j)>=max(2,prm.obs.pntmin)
                iza=[t(j),zeros(length(j),3),tt(j)]; % [ttag,sat,rcv,arcf,trcv]
                iza(:,2)=n; iza(1,4)=1; iza(end,4)=2; % attach arc flags
                izc=[izc;iza]; zc=[zc;zi(j,:)]; azelc=[azelc;azelz(i(j),:)];
                arc=[arc;iza([1,end],5)',n,0,a(3:4)'];
                stats.nobs(n)=stats.nobs(n)+length(j);
                stats.narc(n)=stats.narc(n)+1;
            end
        end
    end
end
if ~isempty(izc), [izc,i]=sortrows(izc,1:2); zc=zc(i,:); azelc=azelc(i,:); end
if ~isempty(arc), arc=sortrows(arc,1:2); end

% estimate receiver position/velocity/clock by point positioning ---------------
function [trcv,rstat,azel]=rcvstate(td,z,iz,sats,rcv,nav,inav,rpos,prm)
C=299792458;
cif=[prm.f1^2;-prm.f2^2]/(prm.f1^2-prm.f2^2); dbgf=0; % pointpos debug (0:nodbg,1:dbg,2:detail)
for n=1:length(sats), navs{n}=nav(inav==n,:); end
trcv=iz(:,1); [t,i]=unique(trcv); i=[1;i+1];
rstat=repmat(nan,length(t),8); rstat(:,1)=t; azel=repmat(nan,size(iz,1),2);
for n=1:length(t)
    j=i(n):i(n+1)-1; zi=z(j,3:4)*cif; k=find(~isnan(zi));
    if isempty(prm.trop), opt=1; else opt=0; end % opt=1: no tropos correction
    [posr,cdtr]=pointpos(td,t(n),zi(k),iz(j(k),2:3),nav,inav,rpos,dbgf,opt);
    trcv(j)=round((trcv(j)-cdtr/C)/prm.ttol)*prm.ttol;
    rstat(n,[2:4,8])=[posr',cdtr];
    for k=j
        [poss,dts,vels,svh]=navtostate(td,iz(k,1),navs{iz(k,2)});
        if ~prm.exuhsat|svh==0
            azel(k,:)=satazel(poss,posr);
        end
    end
end
if any(isnan(rstat(:,2)))
    gt_log('point positioning error : %s nepoch=%d nerr=%d',rcv,length(t),...
           sum(isnan(rstat(:,2))));
end
if size(rstat,1)>1
    omge=7.2921151467E-5; dr=diff(rstat(:,2:4))./repmat(diff(rstat(:,1)),1,3);
    rstat(:,5:7)=([dr(1,:);dr]+[dr;dr(end,:)])/2; % velocity in ecef
    rstat(:,5:7)=rstat(:,5:7)+rstat(:,2:4)*[0,omge,0;-omge,0,0;0,0,0]; % ecef->eci
end

% satellite eclipse periods ----------------------------------------------------
function ecls=eclipsep(td,time,nav,inav,prm)
pos=repmat(nan,[3,length(time),length(prm.sats)]);
for n=1:length(prm.sats)
    navs=nav(inav==n,:);
    for m=1:length(time), pos(:,m,n)=navtostate(td,time(m),navs); end
end
ecls=zeros(length(prm.sats),length(time)); t=repmat(-inf,length(prm.sats),1);
for n=1:length(time)
    utc_tai=prm_utc_tai(td+time(n)/86400,1);
    tu=td+(time(n)+19+utc_tai)/86400;
    [rsun,rmoon]=sunmoonpos(tu);
    U=ecsftoecef(tu,[0,0,0,0,0],utc_tai); psun=U*rsun; pmoon=U*rmoon;
    for m=1:length(prm.sats)
        if shadowfunc(pos(:,n,m),psun,pmoon)<1, t(m)=time(n); end
        if time(n)<=t(m)+prm.ecltime, ecls(m,n)=1; end
    end
end

% separate arc at eclipse boundary ---------------------------------------------
function arcn=separc(time,t,arc,ecls,prm)
arcn=[]; tt=time(ecls(1:end-1)~=ecls(2:end));
if isempty(tt), arcn=arc; return, end
for n=1:size(arc,1)
    a=arc(n,:);
    for i=find(t(a(1))<=tt&tt<t(a(2)))
        j=max(find(t<=tt(i)));
        a=[a;a(end,:)]; a(end-1,2)=j; a(end,1)=j+1;
    end
    arcn=[arcn;a];
end

% generate smoothed codes ------------------------------------------------------
function [z,arcn,mp1,mp2]=smoothcode(time,z,arc,prm)
arcn=[]; mp1=0; mp2=0; n=0; if isempty(arc), return; end

C=299792458; f1=prm.f1; f2=prm.f2;
lam1=C/f1; lam2=C/f2; c1=f1^2/(f1^2-f2^2); c2=f2^2/(f1^2-f2^2);
z=[z,repmat(nan,size(z,1),3)];

for a=arc'
    i=a(1):a(2); i=i(all(~isnan(z(i,1:4)),2));
    
    if ~isempty(i)
        L1=lam1*z(i,1); L2=lam2*z(i,2); P1=z(i,3); P2=z(i,4);
        
        % LC/L1/L2 smoothed code
        N1=mean(L1-P1-2*c2*(P1-P2));
        N2=mean(L2-P2-2*c1*(P1-P2));
        LC=(c1*L1-c2*L2)-(c1*N1-c2*N2);
        if prm.ionwind>0
            I=-(L1-L2)/(1-f1^2/f2^2)-N1+N2;
            I=smoothion(time(i),I,prm.ionwind);
            L1S=L1+I-N1; L2S=L2+f1^2/f2^2*I-N2;
            LC=(L1S+L2S)/2-mean((L1S+L2S)/2-LC);
        end
        z(i,5:7)=[LC,L1-round(N1/lam1)*lam1,L2-round(N2/lam2)*lam2];
        
        % L1/L2 code multipath
        m1=P1-(2*c2+1)*L1+2*c2*L2;
        m2=P2-2*c1*L1+(2*c1-1)*L2;
        mp1=mp1+sum((m1-mean(m1)).^2);
        mp2=mp2+sum((m2-mean(m2)).^2);
        n=n+length(i);
        
        arcn=[arcn;a',N1,N2];
    end
end

% repair clock-jump of steered-clock receiver ----------------------------------
function [z,iz,rstat,log]=fixclkjump(td,z,iz,rcv,rstat,prm)
C=299792458; tz=iz(:,1); tt=rstat(:,1); log={};
dclk=diff(rstat(:,8)/C);
for i=find(abs(dclk)>5E-4)' % detect jump at clock-difference over 0.5msec
    j=find(tt(i+1)<=tz);
    off=round(dclk(i)/1E-3)*1E-3; % jump offset rounded by 1ms
    ttag=rstat(i:i+1,1)-round(rstat(i:i+1,1));
    if prm.obs.clkrep==1 % adjust phase measurement
        z(j,1)=z(j,1)+off*prm.f1;
        z(j,2)=z(j,2)+off*prm.f2;
        flag='P';
    else % adjust time-tag and code measurement
        iz(j,1)=iz(j,1)-off;
        z(j,3:4)=z(j,3:4)-off*C;
        rstat(i+1:end,1)=rstat(i+1:end,1)-off;
        rstat(i+1:end,8)=rstat(i+1:end,8)-off*C;
        flag='C';
    end
    msg=sprintf('%-7s : %s %7.1f  %7.4f %7.4f  %s',rcv,tstr(td,tt(i+1)),...
                off*1E3,ttag,flag);
    log={log{:},msg};
end

% save clean observation data --------------------------------------------------
function saveobs(td,time,rcv,z,iz,arc,rstat,azel,slip,rpos,adel,atype,rtype,prm)
tu=prm.tunit*3600; ts=floor((time(1)+prm.tover*3600)/tu)*tu;
epoch=mjdtocal(td,ts); time=[]; sats=prm.sats; data=z; index=[];
file=sprintf('obsc_%s_%04d%02d%02d%02d.mat',rcv,epoch(1:4));
file=gfilepath(prm.dirs.obc,file,epoch,rcv,1);
if ~isempty(iz)
    time=iz(:,1)-ts; index=[iz(:,2:4),iz(:,5)-ts];
    if ~isempty(rstat), rstat(:,1)=rstat(:,1)-ts; end
    if ~isempty(arc), arc(:,1:2)=arc(:,1:2)-ts; end
    if ~isempty(slip), slip(:,1)=slip(:,1)-ts; end
end
gmsg('saving : %s',file);
save(file,'epoch','time','sats','rcv','data','index','arc','rpos','rstat',...
     'azel','slip','adel','atype','rtype');

% smooth ionospheric variation -------------------------------------------------
function y=smoothion(t,x,twin)
y=repmat(nan,length(x),1); tw=twin/2;
j=1; k=1;
for i=1:length(x)
    for j=j:i, if t(j)>=t(i)-tw, break; end, end
    for k=k:length(x), if t(k)>t(i)+tw, k=k-1; break; end, end
    y(i)=mean(x(j:k));
end

% time string ------------------------------------------------------------------
function s=tstr(td,t), s=sprintf('%04d/%02d/%02d %02d:%02d:%02.0f',mjdtocal(td,t));
function s=pstr(td,time), s=sprintf('%s-%s',tstr(td,time(1)),tstr(td,time(end)));
