function [ sensitivities ] = generateSimulationSentivity(u,x,v,sss,simVars,Jacs,xDims,vDims,uDims,varargin)
%UNTITLED2 Summary of this function goes here
%   Detailed explanation goes here

ss = sss.ss;
jobSchedule = sss.jobSchedule;
imMaster = jobSchedule.imMaster;
fidW = jobSchedule.fidW;

if numel(varargin) == 1
    activeSet = varargin{1};
else % second input option
	lowActive = varargin{1};
	upActive = varargin{2};
	activeSet.lb.x = lowActive.x;
	activeSet.ub.x = upActive.x;
	activeSet.lb.v = lowActive.v;
    activeSet.ub.v = upActive.v;
    if imMaster
   	activeSet.lb.s = lowActive.s;
	activeSet.ub.s = upActive.s;
    end
end
alx = activeSet.lb.x;
aux = activeSet.ub.x;
alv = activeSet.lb.v;
auv = activeSet.ub.v;
%if imMaster
%als = activeSet.lb.s;
%aus = activeSet.ub.s;
%end

if ~isempty(Jacs)
    m = arrayfun(@(JacI)size(JacI.Ju,1),Jacs);
else
    m = 0;
end
if imMaster
[lS,ns] = leftSeedSgen(activeSet,Jacs);
else
lS = nan; %% this is a hack: force a call realization2s in bacward mode. the actual value of lS will not be used.  It will be sent by the master.
ns = nan;
end
[~,Js] = realization2s(x,u,v,sss,'partials',true,'leftSeed',lS);
no = size(Js.Ju,1);
Js.Ju = mat2cell(Js.Ju,no,uDims);


if sum(m) > 0
   Js = sumJacContribution(Js,Jacs,m,'Jx',no);
   Js = sumJacContribution(Js,Jacs,m,'Jv',no);
   Js = sumJacContributionS(Js,Jacs,m,'Ju',no);
    
end
Jsu = Js.Ju;

Js = rmfield(Js,'Ju');
%% Now Js contain the jacobians corresponding to the active set of s and Jacs

%spmd
actCell = realizationActiveSetXV(alx,aux,alv,auv);
[~,JacActXV,nlx,nux,nlv,nuv] = cellfun(@activeSet2TargetXV,actCell,'UniformOutput',false);
%end

JsJx = Js.Jx;
JsJv = Js.Jv;
%spmd
Js = realizationJacsXV(JsJx,JsJv);
[JacActXVJs] = cellfun(@catJacsXV,JacActXV,Js,xDims,vDims,'UniformOutput',false);





Aact = applySimulateSystemZ(u,x,v,ss,simVars,JacActXVJs,fidW);
%%% in Aact
% first  --> activeSet of X and V
% second --> activeSet of S
% third --> jacs

%how to return?
%lbx
%ubx
%lbv
%ubv
%lbs
%ubs
%
% Jacs

[Alx,Aux,Alv,Auv,sJ] = cellfun(@extractGradients,Aact,nlx,nux,nlv,nuv,'UniformOutput',false);

sJ = catAndSum(sJ);
sJ = gopMPI('+',sJ,jobSchedule);
%end


sJ = sJ+cell2mat(Jsu);

Alx = bringVariablesMPI(Alx,jobSchedule);
Aux = bringVariablesMPI(Aux,jobSchedule);
Alv = bringVariablesMPI(Alv,jobSchedule);
Auv = bringVariablesMPI(Auv,jobSchedule);

if imMaster
Aact = [cell2mat([Alx;Aux;Alv;Auv]);sJ(1:ns,:)];


if sum(m) > 0
    mEnd = ns+cumsum(m);
    mStart = 1+[ns;mEnd(1:end-1)];
    sensitivities = arrayfun(@(mS,mE)sJ(mS:mE,:),mStart,mEnd,'UniformOutput',false);
    sensitivities = [sensitivities;{Aact}];
else
    sensitivities = {Aact};
end
sensitivities = cellfun(@(s)mat2cell(s,size(s,1),uDims),sensitivities,'UniformOutput',false);
else
sensitivities =num2cell(num2cell(nan(length(m)+1,1))); 
end

end

function [lS,ns] = leftSeedSgen(act,Jacs)

actl = find(act.lb.s{1});
actu = find(act.ub.s{1});
nl = numel(actl);
nu = numel(actu);

ns = nl+nu;

lSact = sparse(1:ns,[actl;actu],[-ones(nl,1);ones(nu,1)],ns,numel(act.ub.s{1}));

if isempty(Jacs)
    lS = lSact;
else
    Js = vertcat(Jacs(:).Js);
    lS = [lSact;Js];
end

end

function Js = sumJacContribution(Js,Jacs,m,var,no)
mT = sum(m);
to = no-mT;
for k = 1:numel(m)
    from = to+1;
    to = to + m(k);
    if ~isempty(Jacs(k).(var))
        
        Jsvar = Js.(var);
        Jacsvar = Jacs(k).(var);
        %spmd
        Jsvar = sumJacContribS(Jsvar,Jacsvar,from:to);
        %end
        Js.(var) = Jsvar;
    end
end
assert(to==no)
end
function JM = sumJacContribS(JM,J,index)
f = @(JMr,Jr)sumJacContribSr(JMr,Jr,index);
JM = cellfun(f,JM,J,'UniformOutput',false);
end
function JM = sumJacContribSr(JMr,Jr,index)
JM = cellfun(@(JMrk,Jrk)subsAssSumM(JMrk,Jrk,index),JMr,Jr,'UniformOutput',false);
end
function JMrk = subsAssSumM(JMrk,Jrk,index)
JMrk(index,:) = JMrk(index,:)+Jrk;
end
function Js = sumJacContributionS(Js,Jacs,m,var,no)
mT = sum(m);
to = no-mT;
for k = 1:numel(m)
    from = to+1;
    to = to + m(k);
    if ~isempty(Jacs(k).(var))
        Js.(var) = sumJacContribSr(Js.(var),Jacs(k).(var),from:to);
    end
end
assert(to==no)
end

function actCell = realizationActiveSetXV(alx,aux,alv,auv)
actCell = cellfun(@subsActiveSet,alx,aux,alv,auv,'UniformOutput',false);
end
function act = subsActiveSet(alx,aux,alv,auv)
act.lb.x = alx;
act.ub.x = aux;
act.lb.v = alv;
act.ub.v = auv;
end

function J = realizationJacsXV(JacJx,JacJv)
J = cellfun(@subsJacsXV,JacJx,JacJv,'UniformOutput',false);
end

function J = subsJacsXV(Jx,Jv)
J.Jv = Jv;
J.Jx = Jx;
end

function J = catJacsXV(JacActXV,Js,xDims,vDims)

J = catJacs([JacActXV,Js],xDims,vDims,[]);

end

function [Alx,Aux,Alv,Auv,sJ] = extractGradients(Aact,nlx,nux,nlv,nuv)
    Aact = cell2mat(Aact);
    
    index = [nlx;nux;nlv;nuv];
	final = cumsum(index);
    start = [1;1+final(1:end-1)];

	Alx = Aact(start(1):final(1),:);
    Aux = Aact(start(2):final(2),:);
 	Alv = Aact(start(3):final(3),:);
    Auv = Aact(start(4):final(4),:);   

    sJ = Aact(final(4)+1:end,:);

end


function out = catAndSum(M)
if ~isempty(M)
    if iscell(M{1})
        M = cellfun(@cell2mat,M,'UniformOutput',false);
    end
    if any(cellfun(@issparse,M))
        if isrow(M)
            M = M';
        end
        rows= size(M{1},1);
        blocks = numel(M);
        out = sparse( repmat(1:rows,1,blocks),1:rows*blocks,1)*cell2mat(M);
    else
        out = sum(cat(3,M{:}),3);
    end

else
    out = 0;
end
end


function Aact = applySimulateSystemZ(u,x,v,ss,simVars,JacActXVJs,fidW)
nr = numel(ss);

if isempty(fidW)
    printCounter= false;
    printRef = '\b';
    fid = 1;
else
    printCounter= true;
    fid = fidW;
end

Aact = cell(nr,1);

for r = 1:nr
    if printCounter
        printRef = sprintf('%d/%d',r,nr);
    end
    [~,Aact{r}] = ...
        simulateSystemZ(u,x{r},v{r},ss{r},[],...
        'simVars',simVars{r},...
        'JacTar',JacActXVJs{r},...
        'withAlgs',true,...
        'printCounter',printCounter,...
        'fid',fid,...
        'printRef',printRef);
end

end