% REservoir Multiple Shooting Optimization.
% REduced Multiple Shooting Optimization.

% Make sure the workspace is clean before we start
clc
clear
clear global

% Required MRST modules
mrstModule add deckformat
mrstModule add ad-fi

% Include REMSO functionalities
addpath(genpath('../../mrstDerivated'));
addpath(genpath('../../mrstLink'));
addpath(genpath('../../optimization/multipleShooting'));
addpath(genpath('../../optimization/plotUtils'));
addpath(genpath('../../optimization/remso'));
addpath(genpath('../../optimization/remsoSequential'));
addpath(genpath('../../optimization/utils'));
addpath(genpath('reservoirData'));

%% Initialize reservoir -  the Simple reservoir
[reservoirP] = initReservoir( 'simple10x1x10.data','Verbose',true);
%[reservoirP] = initReservoir( 'reallySimpleRes.data','Verbose',true);

% do not display reservoir simulation information!
mrstVerbose off;

% Number of reservoir grid-blocks
nCells = reservoirP.G.cells.num;

%% Multiple shooting problem set up
totalPredictionSteps = numel(reservoirP.schedule.step.val);  % MS intervals

% Schedule partition for each control period and for each simulated step
lastControlSteps = findControlFinalSteps( reservoirP.schedule.step.control );
controlSchedules = multipleSchedules(reservoirP.schedule,lastControlSteps);

stepSchedules = multipleSchedules(reservoirP.schedule,1:totalPredictionSteps);


% Piecewise linear control -- mapping the step index to the corresponding
% control 
ci = @(k) controlIncidence(reservoirP.schedule.step.control,k);


%% Variables Scaling
xScale = setStateValues(struct('pressure',5*barsa,'sW',0.01),'nCells',nCells);


if (isfield(reservoirP.schedule.control,'W'))
    W =  reservoirP.schedule.control.W;
else
    W = processWellsLocal(reservoirP.G, reservoirP.rock,reservoirP.schedule.control(1),'DepthReorder', true);
end
wellSol = initWellSolLocal(W, reservoirP.state);
vScale = wellSol2algVar( wellSolScaling(wellSol,'bhp',5*barsa,'qWs',10*meter^3/day,'qOs',10*meter^3/day) );

cellControlScales = schedules2CellControls(schedulesScaling(controlSchedules,...
    'RATE',10*meter^3/day,...
    'ORAT',10*meter^3/day,...
    'WRAT',10*meter^3/day,...
    'LRAT',10*meter^3/day,...
    'RESV',0,...
    'BHP',5*barsa));


%% Instantiate the simulators for each interval, locally and for each worker.

% ss.stepClient = local (client) simulator instances 
% ss.state = scaled initial state
% ss.nv = number of algebraic variables
% ss.ci = piecewice control mapping on the client side
% ss.step =  worker simulator instances 

step = cell(totalPredictionSteps,1);
for k=1:totalPredictionSteps
    cik = callArroba(ci,{k});
    step{k} = @(x0,u,varargin) mrstStep(x0,u,@mrstSimulationStep,wellSol,stepSchedules(k),reservoirP,'xScale',xScale,'vScale',vScale,'uScale',cellControlScales{cik},varargin{:});
end



ss.state = stateMrst2stateVector( reservoirP.state,'xScale',xScale );
ss.nv = numel(vScale);
ss.step = step;
ss.ci = ci;



%% instantiate the objective function


%%% objective function
nCells = reservoirP.G.cells.num;
objJk = arroba(@NPVStepM,[-1,1,2],{nCells,'scale',1/10000,'sign',-1},true);
obj = cell(totalPredictionSteps,1);
fluid = reservoirP.fluid;
system = reservoirP.system;
for k = 1:totalPredictionSteps
    obj{k} = arroba(@mrstTimePointFuncWrapper,...
        [1,2,3],...
        {...
        objJk,...
        stepSchedules(k),...
        wellSol,...
        fluid,...
        system,...
        'xScale',...
        xScale,...
        'vScale',...
        vScale,...
        'uScale',...
        cellControlScales{callArroba(ci,{k})}...
        },true);
end
targetObj = @(xs,u,vs,varargin) sepTarget(xs,u,vs,obj,ss,varargin{:});

%%  Bounds for all variables!

% Bounds for all wells!
maxProd = struct('BHP',200*barsa);
minProd = struct('BHP',(50)*barsa);
maxInj = struct('RATE',250*meter^3/day);
minInj = struct('RATE',eps);


% Control input bounds for all wells!
[ lbSchedules,ubSchedules ] = scheduleBounds( controlSchedules,...
    'maxProd',maxProd,'minProd',minProd,...
    'maxInj',maxInj,'minInj',minInj,'useScheduleLims',false);
lbu = schedules2CellControls(lbSchedules,'cellControlScales',cellControlScales);
ubu = schedules2CellControls(ubSchedules,'cellControlScales',cellControlScales);

% Bounds for all wells!
maxProd = struct('ORAT',200*meter^3/day,'WRAT',200*meter^3/day,'GRAT',200*meter^3/day,'BHP',200*barsa);
minProd = struct('ORAT',eps,  'WRAT',eps,  'GRAT',eps,'BHP',(50)*barsa);
maxInj = struct('ORAT',250*meter^3/day,'WRAT',250*meter^3/day,'GRAT',250*meter^3/day,'BHP',(400)*barsa);
minInj = struct('ORAT',eps,  'WRAT',eps,  'GRAT',eps,'BHP',(100)*barsa);

% wellSol bounds  (Algebraic variables bounds)
[ubWellSol,lbWellSol] = wellSolScheduleBounds(wellSol,...
    'maxProd',maxProd,...
    'maxInj',maxInj,...
    'minProd',minProd,...
    'minInj',minInj);
ubvS = wellSol2algVar(ubWellSol,'vScale',vScale);
lbvS = wellSol2algVar(lbWellSol,'vScale',vScale);
lbv = repmat({lbvS},totalPredictionSteps,1);
ubv = repmat({ubvS},totalPredictionSteps,1);

% State lower and upper - bounds
maxState = struct('pressure',600*barsa,'sW',1);
minState = struct('pressure',100*barsa,'sW',0.1);
ubxS = setStateValues(maxState,'nCells',nCells,'xScale',xScale);
lbxS = setStateValues(minState,'nCells',nCells,'xScale',xScale);
lbx = repmat({lbxS},totalPredictionSteps,1);
ubx = repmat({ubxS},totalPredictionSteps,1);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Max saturation for well producer cells

% get well perforation grid block set
prodInx  = (vertcat(wellSol.sign) < 0);
wc    = vertcat(W(prodInx).cells);

maxSat = struct('pressure',inf,'sW',1);
ubxS = setStateValues(maxSat,'x',ubxS,'xScale',xScale,'cells',wc);
ubxsatWMax = repmat({ubxS},totalPredictionSteps,1);
ubx = cellfun(@(x1,x2)min(x1,x2),ubxsatWMax,ubx,'UniformOutput',false);



%% Initial Active set!
initializeActiveSet = true;
if initializeActiveSet
    [ lowActive,upActive ] = activeSetFromWells( reservoirP,totalPredictionSteps);
else
    lowActive = [];
    upActive = [];
end


% addpath(genpath('../../optimization/testFunctions'));
% u  = schedules2CellControls( controlSchedules,'cellControlScales',cellControlScales);
%[ errorMax ] = unitTest(u{1},ss,obj,'totalSteps',3,'debug',true)



%% A plot function to display information at each iteration

times.steps = [stepSchedules(1).time;arrayfun(@(x)(x.time+sum(x.step.val))/day,stepSchedules)];
times.tPieceSteps = cell2mat(arrayfun(@(x)[x;x],times.steps,'UniformOutput',false));
times.tPieceSteps = times.tPieceSteps(2:end-1);

times.controls = [controlSchedules(1).time;arrayfun(@(x)(x.time+sum(x.step.val))/day,controlSchedules)];
times.tPieceControls = cell2mat(arrayfun(@(x)[x;x],times.controls,'UniformOutput',false));
times.tPieceControls = times.tPieceControls(2:end-1);

cellControlScalesPlot = schedules2CellControls(schedulesScaling( controlSchedules,'RATE',1/(meter^3/day),...
    'ORAT',1/(meter^3/day),...
    'WRAT',1/(meter^3/day),...
    'LRAT',1/(meter^3/day),...
    'RESV',0,...
    'BHP',1/barsa));

[uMlb] = scaleSchedulePlot(lbu,controlSchedules,cellControlScales,cellControlScalesPlot);
[uLimLb] = min(uMlb,[],2);
ulbPlob = cell2mat(arrayfun(@(x)[x,x],uMlb,'UniformOutput',false));


[uMub] = scaleSchedulePlot(ubu,controlSchedules,cellControlScales,cellControlScalesPlot);
[uLimUb] = max(uMub,[],2);
uubPlot = cell2mat(arrayfun(@(x)[x,x],uMub,'UniformOutput',false));


% be carefull, plotting the result of a forward simulation at each
% iteration may be very expensive!
% use simFlag to do it when you need it!
simFunc =@(sch) runScheduleADI(reservoirP.state, reservoirP.G, reservoirP.rock, reservoirP.system, sch);


wc    = vertcat(W.cells);
fPlot = @(x)[max(x);min(x);x(wc)];

%prodInx  = (vertcat(wellSol.sign) < 0);
%wc    = vertcat(W(prodInx).cells);
%fPlot = @(x)x(wc);

plotSol = @(x,u,v,d,varargin) plotSolution( x,u,v,d,ss,obj,times,xScale,cellControlScales,vScale,cellControlScalesPlot,controlSchedules,wellSol,ulbPlob,uubPlot,[uLimLb,uLimUb],minState,maxState,'simulate',simFunc,'plotWellSols',true,'plotSchedules',false,'pF',fPlot,'sF',fPlot,varargin{:});

%%  Initialize from previous solution?

if exist('optimalVars.mat','file') == 2
    load('optimalVars.mat','x','u','v');
elseif exist('itVars.mat','file') == 2
    load('itVars.mat','x','u','v');
else
	x = [];
    v = [];
    u  = schedules2CellControls( controlSchedules,'cellControlScales',cellControlScales);
    %[x] = repmat({ss.state},totalPredictionSteps,1);
end


%% call REMSO

[u,x,v,f,d,M,simVars] = remso(u,ss,targetObj,'lbx',lbx,'ubx',ubx,'lbv',lbv,'ubv',ubv,'lbu',lbu,'ubu',ubu,...
    'tol',1e-6,'lkMax',4,'debugLS',true,...
    'lowActive',lowActive,'upActive',upActive,...
    'plotFunc',plotSol,'max_iter',500,'x',x,'v',v,'debugLS',false,'saveIt',false);

%% plotSolution
plotSol(x,u,v,d,'simFlag',true);

%% Save result?
%save optimalVars u x v f d M
