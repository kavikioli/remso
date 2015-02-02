function [u,x,v,f,xd,M,simVars] = remso(u,ss,obj,varargin)
% REMSO
% REservoir Multiple Shooting Optimization.
% REduced Multiple Shooting Optimization.
%
% This is the main interface to the REMSO solver.
%
% SYNOPSIS:
%  [u,x,v,f,xd,M,simVars] = remso(u, ss, obj)
%  [u,x,v,f,xd,M,simVars] = remso(u, ss, obj, 'pn', pv, ...)
% PARAMETERS:
%   u - cellarray containing a initial control guess for each control
%       period.
%
%   ss - A simulator structure, containing all the required
%        information on the model.
%
%   obj - A nonlinear function structure defining the objective function
%
%   'pn'/pv - List of 'key'/value pairs defining optional parameters. The
%             supported options are:
%
%   lbx - State lower bound for each point in the prediction horizon.
%
%   ubx - State upper bound for each point in the prediction horizon.
%
%   lbv - Algebraic state lower bound for each point in the prediction horizon.
%
%   ubv - Algebraic state upper bound for each point in the prediction horizon.
%
%   lbxH - State hard lower bound for each point in the prediction horizon.
%
%   ubxH - State hard  upper bound for each point in the prediction horizon.
%
%   lbvH - Algebraic state hard lower bound for each point in the prediction horizon.
%
%   ubvH - Algebraic state hard upper bound for each point in the prediction horizon.
%
%   lbu - Control input lower bound for each control period.
%
%   ubu - Control input upper bound for each control period.
%
%   tol - Master tolerance.
%
%   tolU - Convergence tolerance for the controls.
%
%   tolX - Convergence tolerance for the states.
%
%   tolV - Convergence tolerance for the algebraic variables.
%
%   max_iter - Maximum iterations allowed for the main algorithm.
%
%   M - Initial reduced hessian approximation.
%
%   x - Initial guess for the states in the prediction horizon..
%
%   v - Initial guess for the algebraic states in the control horizon.
%
%   plotFunc - plotFunc(x,u,v,xd).  Plot function for the current solution
%              iterate.
%
%   lkMax - Maximum number of evaluated points during line-search.
%
%   eta - Constant related to the Wolf curvature condition.
%
%   tauL - Constant related to the minimum descent condition.
%
%   debugLS - Plot debug information during line-search.
%
%   qpDebug - Print debug information related to the QP solving process.
%
%   lowActive - Initial active set estimate related to the lower bounds.
%
%   upActive - Initial active set estimate related to the upper bounds.
%
%   simVars - Simulation variables, for hot start initialization.
%
%   debug - Print debug information containing general algorithm
%           performance.
%
%   plot - Flag to allow plotting at each iteration.
%
%   saveIt - Save current iterate variables at each iteratoin.
%
%
% RETURNS:
%
%   u - Optimal control estimate.
%
%   x - State forecast.
%
%   v - Algebraic state forecast.
%
%   f - Estimated objective function value.
%
%   xd - State forecast error estimation.
%
%   M - Hessian approximation.
%
%   simVars - Final simulation variables.
%
% SEE ALSO:
%
%
%{

Copyright 2013-2014, Andres Codas.

REMSO is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

REMSO is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with REMSO.  If not, see <http://www.gnu.org/licenses/>.

%}
opt = struct('lbx',[],'ubx',[],'lbv',[],'ubv',[],'lbu',[],'ubu',[],...
             'lbxH',[],'ubxH',[],'lbvH',[],'ubvH',[],...
    'tol',1e-1,'tolU',1e-2,'tolX',1e-2,'tolV',1e-2,'max_iter',50,...
    'M',[],'x',[],'v',[],...
    'plotFunc',[],...
    'BFGSRestartscale', true,'BFGSRestartmemory',6,...
    'lkMax',4,'eta',0.1,'tauL',0.1,'debugLS',false,'curvLS',true,...
    'qpDebug',true,...
    'lowActive',[],'upActive',[],...
    'simVars',[],'debug',true,'plot',false,'saveIt',false,'controlWriter',[],...
    'multiplierFree',inf,...
    'allowDamp',true);

opt = merge_options(opt, varargin{:});




% extract information on the prediction horizon and control intervals
totalPredictionSteps = getTotalPredictionSteps(ss);
totalControlSteps = numel(u);

% number of variables
nx = numel(ss.state);
nu = numel(u{1});
nv = ss.nv;

% true if dealing with algebraic states
withAlgs = (nv>0);

% dimension of the control space, dimension of the reduced problem
nru = numel(cat(2,u{:}));

%% Control, state and algebraic state bounds processing
uDims = cellfun(@(uu)size(uu,1),u);
uV = cell2mat(u);
if isempty(opt.lbu)
    lbu = [];
else
    lbu = cell2mat(opt.lbu);
    if ~all(uV-lbu >=0)
        warning('Make a feasible first guess of the control variables: chopping controls')
        uV = max(uV,lbu);
        u = mat2cell(uV,uDims,1);
    end
end
if isempty(opt.ubu)
    ubu = [];
else
    ubu = cell2mat(opt.ubu);
    if ~all(ubu-uV >=0)
        warning('Make a feasible first guess of the control variables: chopping controls')
        uV = min(uV,ubu);
        u = mat2cell(uV,uDims,1);
    end
end
if isempty(opt.lbx)
    opt.lbx = repmat({-inf(nx,1)},totalPredictionSteps,1);
end
if isempty(opt.ubx)
    opt.ubx = repmat({inf(nx,1)},totalPredictionSteps,1);
end
if withAlgs && isempty(opt.lbv)
    opt.lbv = repmat({-inf(nv,1)},totalPredictionSteps,1);
end
if withAlgs && isempty(opt.ubv)
    opt.ubv = repmat({inf(nv,1)},totalPredictionSteps,1);
end

checkHardConstraints = false;
if isempty(opt.lbxH)
    opt.lbxH = repmat({-inf(nx,1)},totalPredictionSteps,1);
else
    checkHardConstraints = true;
end
if isempty(opt.ubxH)
    opt.ubxH = repmat({inf(nx,1)},totalPredictionSteps,1);
else
    checkHardConstraints = true;    
end
if withAlgs && isempty(opt.lbvH)
    opt.lbvH = repmat({-inf(nv,1)},totalPredictionSteps,1);
else
    checkHardConstraints = true;    
end
if withAlgs && isempty(opt.ubvH)
    opt.ubvH = repmat({inf(nv,1)},totalPredictionSteps,1);
else
    checkHardConstraints = true;
end

% solf bounds must be bounded by hard bounds
if checkHardConstraints
    
    opt.lbx = cellfun(@(l1,l2)max(l1,l2),opt.lbx,opt.lbxH,'UniformOutput',false);
    opt.ubx = cellfun(@(l1,l2)min(l1,l2),opt.ubx,opt.ubxH,'UniformOutput',false);
	
	if withAlgs
        opt.lbv = cellfun(@(l1,l2)max(l1,l2),opt.lbv,opt.lbvH,'UniformOutput',false);
        opt.ubv = cellfun(@(l1,l2)min(l1,l2),opt.ubv,opt.ubvH,'UniformOutput',false);
	end
    
end


udv = [];
ldv = [];
dv = [];

% Multiple shooting simulation function
simFunc = @(xk,uk,varargin) simulateSystem(xk,uk,ss,varargin{:});


%% Define empty active sets if they are not given
if isempty(opt.lowActive)
    opt.lowActive.x = cellfun(@(x)false(size(x)),opt.lbx,'UniformOutput',false);
    if withAlgs
        opt.lowActive.v = cellfun(@(x)false(size(x)),opt.lbv,'UniformOutput',false);
    end
end
if isempty(opt.upActive)
    opt.upActive.x = cellfun(@(x)false(size(x)),opt.ubx,'UniformOutput',false);
    if withAlgs
        opt.upActive.v = cellfun(@(x)false(size(x)),opt.ubv,'UniformOutput',false);
    end
end

%% initial simulation profile
if isempty(opt.simVars)
    simVars = cell(totalPredictionSteps,1);
else
    simVars = opt.simVars;
end

%% Process initial MS simulation guess, if not given, get it by forward simulation
simulateSS = false;
if ~isempty(opt.x)
    %  Initial guess for prediction given by the user
    x = opt.x;
    xs = opt.x;
else
    % Initial guess not provided, take from a simulation in the gradient
    % routine
    simulateSS = true;
    x = [];
    xs = [];
end
if withAlgs
    if isempty(opt.v)
        v = repmat({zeros(nv,1)},totalPredictionSteps,1);
        vs = [];
    else
        v = opt.v;
        vs = opt.v;
    end
else
    v = [];
    vs = [];
end

if simulateSS
	[~,~,~,simVars,xs,vs,usliced] = simulateSystemSS(u,ss,[],'guessX',xs,'guessV',vs,'simVars',simVars);
    x = xs;
    v = vs;
else
    [xs,vs,~,~,simVars,usliced] = simulateSystem(x,u,ss,'gradients',false,'guessX',xs,'guessV',vs,'simVars',simVars);
end


[~,x]  = checkBounds( opt.lbx,x,opt.ubx,'chopp',true,'verbose',opt.debug);
if withAlgs
    [~,v]  = checkBounds( opt.lbv,v,opt.ubv,'chopp',true,'verbose',opt.debug);
end



%% lagrange multipliers estimate initilization
mudx= repmat({zeros(nx,1)},totalPredictionSteps,1);
mudu = repmat({zeros(nu,1)},totalControlSteps,1);
if withAlgs
    mudv = repmat({zeros(nv,1)},totalPredictionSteps,1);
end


%% Hessian Initializaiton
if(isempty(opt.M))
    hInit = true;
    M = eye(nru);
else
    hInit = false;
    M = opt.M;
end

% clean debug file
if opt.debug
    fid = fopen('logBFGS.txt','w');
    fclose(fid); 
end


%% Curvature history record
y = zeros(1,sum(uDims));
s = zeros(sum(uDims),1);
sTy = 0;

S = [];
Y = [];



%% Line-search parameters
rho = 1/(totalPredictionSteps*(nx+nv));
rhoHat = rho/100;
returnVars = [];
relax = false;   % to avoid the hessian update and perform a fine line-search
errorSumB = [];
dualApproxB = [];
tau = [];


%%  This file allows you to stop the algorithm for debug during execution.
% If the file is deleted, the algorithm will stop at the predefined set
% points.
if opt.debug
    fid = fopen('deleteMe2Break.txt','w');fclose(fid);
end

% convergence flag
converged = false;


%% Algorithm main loop
for k = 1:opt.max_iter
    
    %%% Meanwhile condensing, study to remove this
    [xs,vs,xd,vd,ax,Ax,av,Av]  = condensing(x,u,v,ss,'simVars',simVars,'computeCorrection',true);
    
    [f,objPartials] = obj(x,u,v,'gradients',true);
    
    if withAlgs
        gZ = vectorTimesZ(objPartials.Jx,objPartials.Ju,objPartials.Jv,Ax,Av,ss.ci );
    else
        gZ = vectorTimesZ(objPartials.Jx,objPartials.Ju,[],Ax,[],ss.ci );
    end
    
    gbar.x =  cellfun(@(Jz,m)(Jz+m'),objPartials.Jx,mudx','UniformOutput',false);
    gbar.u =  cellfun(@(Jz,m)(Jz+m'),objPartials.Ju,mudu','UniformOutput',false);
    if withAlgs
        gbar.v = cellfun(@(Jz,m)(Jz+m'),objPartials.Jv,mudv','UniformOutput',false);
    end
    
    if withAlgs
        gbarZ = vectorTimesZ(gbar.x,gbar.u,gbar.v,Ax,Av,ss.ci );
    else
        gbarZ = vectorTimesZ(gbar.x,gbar.u,[],Ax,[],ss.ci );
    end
    
    % TODO: after finished check all input and outputs, in particular
    % uSliced!

    
    % Honor hard bounds in every step. Cut step if necessary
    [w,stepY] = computeCrossTerm(x,u,v,ax,av,gbarZ,ss,obj,mudx,mudu,mudv,opt.lbxH,opt.lbvH,opt.ubxH,opt.ubvH,withAlgs,'xs',xs,'vs',vs);
    zeta = 1;%computeZeta( gZ,M,w );
    

    % plot initial iterate
    if ~isempty(opt.plotFunc) && k == 1 && opt.plot
        opt.plotFunc(x,u,v,xd);
    end
    
    % debug cheack-point, check if the file is present
    if opt.debug
        fid = fopen('deleteMe2Break.txt','r');
        if fid == -1
            fid = fopen('deleteMe2Break.txt','w');fclose(fid);
            keyboard;
        else
            fclose(fid);
        end
    end
    
    %% Update hessian approximation
    
    if relax  % Do not perform updates if the watchdog is active!
        
        
        
        y = cellfun(@(gbarZi,gbarZmi,wbari)gbarZi-gbarZmi-wbari,gbarZ,gbarZm,wbar,'UniformOutput',false);
        y = cell2mat(y);
        s = uV-uBV;
        
        % Perform the BFGS update and save information for restart
        if hInit
            M = [];
            [M,S,Y, skipping,sTy] = dampedBFGSLimRestart(M,y,s,nru,S,Y,'scale',opt.BFGSRestartscale,'it',k,'m',opt.BFGSRestartmemory,'allowDamp',opt.allowDamp);
            hInit = skipping;
        else
            [ M,S,Y,~,sTy ] = dampedBFGSLimRestart(M,y,s,nru,S,Y,'scale',opt.BFGSRestartscale,'it',k,'m',opt.BFGSRestartmemory,'allowDamp',opt.allowDamp);
        end
        
    end
    
    
    %% Compute search direction  && lagrange multipliers
    
    % Compute bounds for the linearized problem
    udu =  cellfun(@(w,e,r)(w-e),opt.ubu,u,'UniformOutput',false);
    ldu =  cellfun(@(w,e,r)(w-e),opt.lbu,u,'UniformOutput',false);
    
    udx =  cellfun(@(w,e,r)(w-e),opt.ubx,x,'UniformOutput',false);
    ldx =  cellfun(@(w,e,r)(w-e),opt.lbx,x,'UniformOutput',false);
    if withAlgs
        udv =  cellfun(@(w,e,r)(w-e),opt.ubv,v,'UniformOutput',false);
        ldv =  cellfun(@(w,e,r)(w-e),opt.lbv,v,'UniformOutput',false);
    end
    
    
    qpGrad = cellfun(@(gZi,wi)gZi+zeta*wi,gZ,w,'UniformOutput',false);
    
    % Solve the QP to obtain the step on the nullspace.
    [ du,dx,dv,xi,opt.lowActive,opt.upActive,muH,violationH,qpVAl,dxN,dvN] = qpStep(M,qpGrad,...
        ldu,udu,...
        ax,Ax,ldx,udx,...
        av,Av,ldv,udv,...
        'lowActive',opt.lowActive,'upActive',opt.upActive,...
        'ci',ss.ci,...
        'qpDebug',opt.qpDebug,'it',k);
    
    % debug check-point, check if the file is present
    if opt.debug
        fid = fopen('deleteMe2Break.txt','r');
        if fid == -1
            fid = fopen('deleteMe2Break.txt','w');fclose(fid);
            keyboard;
        else
            fclose(fid);
        end
    end
    
    % Honor hard bounds in every step. Cut step if necessary
    [maxStep,du] = maximumStepLength(u,du,opt.lbu,opt.ubu);
    
    [maxStepx,dx] = maximumStepLength(x,dx,opt.lbx,opt.ubx);
    maxStep = min(maxStep,maxStepx);
    if withAlgs
        [maxStepv,dv] =maximumStepLength(v,dv,opt.lbv,opt.ubv);
        maxStep = min(maxStep,maxStepv);
    end
    
    
    
    
    %% Convergence test
    % I choose the infinity norm, because this is easier to relate to the
    % physical variables
    normdu = norm(cellfun(@(z)norm(z,'inf'),du),'inf');
    normax = norm(cellfun(@(z)norm(z,'inf'),ax),'inf');
    normav = norm(cellfun(@(z)norm(z,'inf'),av),'inf');
    
    if normdu < opt.tolU && normax < opt.tolX && normav < opt.tolV && normdu < opt.tol && normax < opt.tol && normav < opt.tol && violationH(end) < opt.tol && relax
        converged = true;
        break;
    end
    
    %% Preparing for line-search
    
    % gbar = g+nu
    gbar.x =  cellfun(@(Jz,mub,mul)(Jz+(mub-mul)'),objPartials.Jx,muH.ub.x',muH.lb.x','UniformOutput',false);
    gbar.u =  cellfun(@(Jz,mub,mul)(Jz+(mub-mul)'),objPartials.Ju,muH.ub.u',muH.lb.u','UniformOutput',false);
    if withAlgs
        gbar.v = cellfun(@(Jz,mub,mul)(Jz+(mub-mul)'),objPartials.Jv,muH.ub.v',muH.lb.v','UniformOutput',false);
    end
    

    
    
    
    if relax || k == 1

        if  k > opt.multiplierFree
            gbarLambda.Jx = gbar.x;
            gbarLambda.Ju = gbar.u;
            if withAlgs
                gbarLambda.Jv = gbar.v;
            end
            [~,~,~,~,~,~,~,lambdaX,lambdaV]= simulateSystemZ(u,xd,vd,ss,[],'gradients',true,'guessX',xs,'guessV',vs,'simVars',simVars,'JacTar',gbarLambda);

            %{

            % first order optimality condition!
            [~,~,Jac,~,~,~] = simulateSystem(x,u,ss,'gradients',true,'xLeftSeed',lambdaX,'vLeftSeed',lambdaV,'guessX',xs,'guessV',vs,'simVars',simVars);

            optCond.x =  cellfun(@(gbari,lambdaCi,lambdai)(gbari+(lambdaCi-lambdai)),gbarLambda.Jx,Jac.Jx,lambdaX,'UniformOutput',false);
            optCond.u =  cellfun(@(gbari,lambdaCi)(gbari+lambdaCi),gbarLambda.Ju,Jac.Ju,'UniformOutput',false);
            if withAlgs
                optCond.v = cellfun(@(gbari,lambdai)(gbari-lambdai),gbarLambda.Jv,lambdaV,'UniformOutput',false);
            end

            %}        
            normInfLambda = max(cellfun(@(xv)max(abs(xv)),[lambdaX,lambdaV]));
            
        else
            normInfLambda = -inf;

        end        
        
        
        if xi ~= 1
            % multiplier free approximations
            [gbarR,errorSum,crossProduct] = multiplierFreeApproxs(gbar,ax,av,xd,vd,w,du,xi,withAlgs);
            % calculate equality constraints penalty
            [rho,errorSumB,dualApproxB] = equalityConsPenalty(gbarR,errorSum,crossProduct,rho,rhoHat,errorSumB,dualApproxB,normInfLambda);
        else
            warning('xi == 1. The problem may be infeasible to solve');
        end
    end
    
    %% Merit function definition
    merit = @(f,dE,varargin) l1merit(f,dE,rho,varargin{:});
    % line function
    phi = @(l,varargin) lineFunctionWrapper(l,...
        x,...
        v,...
        u,...
        dx,...
        dv,...
        du,...
        simFunc,obj,merit,'gradients',true,'plotFunc',opt.plotFunc,'plot',opt.plot,...
        'debug',opt.debug,...
        'xd0',xd,...
        'vd0',vd,...
        'xs0',xs,...
        'vs0',vs,...
        'xi',xi,...
        varargin{:});
   
    
    % do not perform a watch-dog step on the very first iteration! 
    if k<=1
        skipWatchDog = true;
    else
        skipWatchDog = false;
    end
    
    % Line-search 
    [l,~,~,~,xfd,vars,simVars,relax,returnVars,wentBack,debugInfo] = watchdogLineSearch(phi,relax,...
        'tau',opt.tauL,'eta',opt.eta,'kmax',opt.lkMax,'debugPlot',opt.debugLS,'debug',opt.debug,...
        'simVars',simVars,'curvLS',opt.curvLS,'returnVars',returnVars,'skipWatchDog',skipWatchDog,'maxStep',maxStep,'k',k);
    
    
    if relax == false && (debugInfo{2}.eqNorm1 > debugInfo{1}.eqNorm1)  %% Watchdog step activated, should we perform SOC?
        
        
        % build the new problem!
        
        xdSoc = cellfun(@(vxsi,vxi,xdi)vxsi-vxi+(1-xi)*xdi,vars.xs,vars.x,xd,'UniformOutput',false);
        if withAlgs
            vdSoc = cellfun(@(vvsi,vvi,vdi)vvsi-vvi+(1-xi)*vdi,vars.vs,vars.v,vd,'UniformOutput',false);
        else
            vdSoc = [];
        end
                
        [~,~,~,~,axSOC,~,avSOC,~] = condensing(x,u,v,ss,'simVars',simVars,'computeCorrection',true,'computeNullSpace',false,'xd',xdSoc,'vd',vdSoc);
        
        [wSOC,stepYSOC] = computeCrossTerm(x,u,v,axSOC,avSOC,gbarZ,ss,obj,mudx,mudu,mudv,opt.lbxH,opt.lbvH,opt.ubxH,opt.ubvH,withAlgs,'xs',xs,'vs',vs);

   
       
    
        qpGrad = cellfun(@(gZi,wi)gZi+zeta*wi,gZ,wSOC,'UniformOutput',false);
    
        % Solve the QP to obtain the step on the nullspace.
        [ duSOC,dxSOC,dvSOC,xiSOC,lowActiveSOC,upActiveSOC,muHSOC,violationHSOC,qpVAlSOC,dxNSOC,dvNSOC] = qpStep(M,qpGrad,...
            ldu,udu,...
            axSOC,Ax,ldx,udx,...
            avSOC,Av,ldv,udv,...
            'lowActive',opt.lowActive,'upActive',opt.upActive,...
            'ci',ss.ci,...
            'qpDebug',opt.qpDebug,'it',k);
        
        % debug check-point, check if the file is present
        if opt.debug
            fid = fopen('deleteMe2Break.txt','r');
            if fid == -1
                fid = fopen('deleteMe2Break.txt','w');fclose(fid);
                keyboard;
            else
                fclose(fid);
            end
        end
        
        % Honor hard bounds in every step. Cut step if necessary
        [maxStep,duSOC] = maximumStepLength(u,duSOC,opt.lbu,opt.ubu);
        
        [maxStepx,dxSOC] = maximumStepLength(x,dxSOC,opt.lbx,opt.ubx);
        maxStep = min(maxStep,maxStepx);
        if withAlgs
            [maxStepv,dvSOC] =maximumStepLength(v,dvSOC,opt.lbv,opt.ubv);
            maxStep = min(maxStep,maxStepv);
        end
        
        
        %trystep
        % TODO: implement function without calculating gradients!
        [ fSOC,dfSOC,varsSOC,simVarsSOC,debugInfoSOC ] = lineFunctionWrapper(1,...
            x,...
            v,...
            u,...
            dxSOC,...
            dvSOC,...
            duSOC,...
            simFunc,obj,merit,'gradients',true,'plotFunc',opt.plotFunc,'plot',opt.plot,...
            'debug',opt.debug);
        
        
        
        
        %Try full Step
        
        xfd = [xfd;1 fSOC dfSOC];
        
        armijoF = @(lT,fT)  (fT - (xfd(1,2) + opt.eta*xfd(1,3)*lT));
        armijoOk = @(lT,fT) (armijoF(lT,fT) <= 0);
        
        
        debugInfoSOC.armijoVal = armijoF(1,fSOC);
        debugInfo = [debugInfo;debugInfoSOC];
              
        
        if armijoOk(1,fSOC)  %% accept this step!
            ax = axSOC;
            av = avSOC;
            du = duSOC;
            dx = dxSOC;
            dv = dvSOC;
            xi = xiSOC;
            opt.lowActive = lowActiveSOC;
            opt.upActive = upActiveSOC;
            muH = muHSOC;
            violationH = violationHSOC;
            qpVAl = qpVAlSOC;
            dxN = dxNSOC;
            dvN = dvNSOC;
            w = wSOC;
            muH = muHSOC;
            l=1;
            vars = varsSOC;
            simVars = simVarsSOC;
            relax = true;
            returnVars = [];
            wentBack = false;
            debugWatchdog( k,'C',xfd(end,1),xfd(end,2),xfd(end,3),debugInfo(end));
        else
            debugWatchdog( k,'X',xfd(end,1),xfd(end,2),xfd(end,3),debugInfo(end));
        end
        
        
    
    end

   
 

    % debug cheack-point, check if the file is present
    if opt.debug
        fid = fopen('deleteMe2Break.txt','r');
        if fid == -1
            fid = fopen('deleteMe2Break.txt','w');fclose(fid);
            keyboard;
        else
            fclose(fid);
        end
    end
    
    % Restore previous lagrange multiplier estimate, if the Watch-dog
    % returned from a previous estimate
    if wentBack 
        mudx = muReturnX;
        if withAlgs
            mudv = muReturnV;
        end
        mudu = muReturnU;
        muH = muHReturn;
    end
    % Save Lagrange multipliers to restore if necessary
    if ~isempty(returnVars)
        muReturnX = mudx;
        if withAlgs
            muReturnV = mudv;
        end
        muReturnU = mudu;
        muHReturn = muH;
    else
        muReturnX = [];
        muReturnU = [];
        muReturnV = [];
        muHReturn = [];
    end
    
    %Update dual variables estimate
    mudx = cellfun(@(x1,x2,x3)(1-l)*x1+l*(x2-x3),mudx,muH.ub.x,muH.lb.x,'UniformOutput',false);
    mudu = cellfun(@(x1,x2,x3)(1-l)*x1+l*(x2-x3),mudu,muH.ub.u,muH.lb.u,'UniformOutput',false);
    if withAlgs
        mudv = cellfun(@(x1,x2,x3)(1-l)*x1+l*(x2-x3),mudv,muH.ub.v,muH.lb.v,'UniformOutput',false);
    end
    
    if l == 1
        wbar = w;
    else
        wbar = cellfun(@(wi)l*wi,w,'UniformOutput',false);
    end
    
    %TODO: implement a saturation for wbar!
    
    
    % computed only if alpha ~= 1  TODO: check watchdog condition
    if l ~=1
        gbar.x =  cellfun(@(Jz,m)(Jz+m'),objPartials.Jx,mudx','UniformOutput',false);
        gbar.u =  cellfun(@(Jz,m)(Jz+m'),objPartials.Ju,mudu','UniformOutput',false);
        if withAlgs
            gbar.v = cellfun(@(Jz,m)(Jz+m'),objPartials.Jv,mudv','UniformOutput',false);
        end
    end
    
    
    % calculate the lagrangian with the updated values of mu, this will
    % help to perform the BFGS update
    if withAlgs
        gbarZm = vectorTimesZ(gbar.x,gbar.u,gbar.v,Ax,Av,ss.ci );
    else
        gbarZm = vectorTimesZ(gbar.x,gbar.u,[],Ax,[],ss.ci );
    end
    
    if opt.debug
        printLogLine(k,...
            {'|(g+nu)Z|','|c|','|Ypy|','|Zpz|','xi','|gZ|','|w|','pz''w','stepY','l','|s|','|y|','s''y','cond(B)'},...
            {...
            sqrt(sum(cellfun(@(x)dot(x,x),gbarZm))),...
            sqrt(sum(cellfun(@(x)dot(x,x),[xd;vd]))),...
            sqrt(sum(cellfun(@(x)dot(x,x),[ax;av]))),...
            sqrt(sum(cellfun(@(x)dot(x,x),[dxN;dvN;du]))),...
            xi,...
            sqrt(sum(cellfun(@(x)dot(x,x),gZ))),...
            sqrt(sum(cellfun(@(x)dot(x,x),w))),...
            sum(cellfun(@mtimes,w,du')),...
            stepY,...
            l,...
            norm(s),...
            norm(y),...
            sTy,...
            cond(M)...
            }...
            );
    end
    
    % save last value of u for the BFGS update
    uBV = cell2mat(u);
    
    % return the new iterate returned after line-search.
    x = vars.x;
    xs = vars.xs;
    if withAlgs
        v =  vars.v;
        vs = vars.vs;
    end
    u = vars.u;

	[~,u]  = checkBounds( opt.lbu,u,opt.ubu,'chopp',true,'verbose',opt.debug);
    [~,x]  = checkBounds( opt.lbx,x,opt.ubx,'chopp',true,'verbose',opt.debug);
    if withAlgs
        [~,v]  = checkBounds( opt.lbv,v,opt.ubv,'chopp',true,'verbose',opt.debug);
    end    
    uV = cell2mat(u);

    usliced = vars.usliced;
    
    % Save the current iteration to a file, for debug purposes.
    if opt.saveIt
        save itVars x u v xd vd rho M;
    end
    if ~isempty(opt.controlWriter)
        opt.controlWriter(u,k);
    end
    
    
    % print main debug
    if  opt.debug
        if mod(k,10) == 1
            header = true;
        else
            header = false;
        end
        tMax = 0;
        
        
        dispFunc(k,norm(cell2mat(gbarZm)),violationH,normdu,rho,tMax,xfd,cond(M),relax,debugInfo,header );
    end
    
    if l == 0  %line search couldn't make a sufficient decrease
        warning('lineSearch determined 0 step length');
        break;
    end
    
    
end


% recover previous variables if you performed a watch-dog step in the last iteration
if ~converged &&  ~relax
    x = returnVars.vars0.x;
    u = returnVars.vars0.u;
    if withAlgs
        v = returnVars.vars0.v;
    end
    simVars = returnVars.simVars0;
    [xs,vs,~,~,simVars] = simulateSystem(x,u,ss,'guessV',v,'simVars',simVars);
    f = obj(xs,u,v,'gradients',false);
    xd = cellfun(@(x1,x2)x1-x2,xs,x,'UniformOutput',false);
    
end

