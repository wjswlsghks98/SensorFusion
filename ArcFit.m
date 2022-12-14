classdef ArcFit < handle
    %ARCFIT NLS based Arc Spline Optimization given data points
    %
    %   Given data points and initial arc parameters, this solver module
    %   finds the optimal arc parameter set.
    %    
    %   [NLS Models]
    %   Model 1: Arc-Point Measurement Model
    %   Model 2: Arc Initial/Final Point Anchoring Model
    %
    %   [Optimization Variables]
    %   x0, y0, tau0, kappa1, ..., kappaN
    %   --> Only arc parameters are to be optimized
    %   
    %   [Assumptions]
    %   * We assume that all association (which point to which segment) is
    %     totally fixed throughout the optimization process
    %   * Association is performed once at the beginning, according to the
    %     input boundary data(params.bnds)! (No geometric association)
    % 
    %   [Todos]
    %   To speed up the numerical jacobian computation process, create
    %   sparsity pattern (Algebraic jacobian is unstable)
    %
    %   Implemented by JinHwan Jeon, 2022

    properties(Access = public)
        id % Segment ID
        params % Segment Parameters: x0,y0,tau0,kappa1~N,L1~N        
        points % Input 2D data points       
        covs % Input 2D data points covariance (Used for validity check)       
        valid = false % Validity of current optimized parameter set
        validity % Number of invalid points for each segment
        assoc % Indicates which segment index the data point is matched to
        matchedPoints % Matched arc points (for each data point)
        Ndist % Normalized Mahalanobis distance (Weighted Error)
        precomp_jac = struct() % Not Used: Deprecated (Fast Jacobian Computation)
        opt = struct() % Optimized results : jacobian, information matrix, covariance matrix
    end

    methods(Access = public)        
        %% Constructor
        function obj = ArcFit(params,points,covs,id)
            obj.id = id;
            obj.params = params;
            obj.points = points;            
            obj.covs = covs;            
            obj.assoc = zeros(1,size(obj.points,2));
        end
            
        %% Retrieve params 
        function params = getParams(obj)
            params = obj.params;
        end
        
        %% Optimize
        function obj = optimize(obj)
            obj.associate();
            % Perform ArcBaseFit to get stablized arc parameters
            obj.TestArcFitBase();
            
            if obj.id ~= 100
                while ~obj.valid
                    obj.associate();
    
                    jac_pattern = obj.getJacPattern();
                    
                    disp(['[Performing Optimization for Segment ID: ',num2str(obj.id),']']) 
                    X0 = [obj.params.x0; obj.params.y0; obj.params.tau0; 1./obj.params.kappa'];
        
                    n = length(obj.params.kappa);
    %                 lb = [repmat(-inf,1,3+n),zeros(1,n)];
                    lb = [];
                    ub = [];
                    options = optimoptions('lsqnonlin', ...
                                           'UseParallel',true, ...
                                           'Display','iter-detailed', ...
                                           'MaxFunctionEvaluations',3e4, ...    
                                           'MaxIterations',200, ...
                                           'FiniteDifferenceType','forward', ...
                                           'JacobPattern',jac_pattern);
                    [X,~,~,~,~,~,jacobian] = lsqnonlin(@obj.cost_func,X0,lb,ub,options);
                    
                    obj.params.x0 = X(1);
                    obj.params.y0 = X(2);
                    obj.params.tau0 = X(3);
                    obj.params.kappa = 1./X(3+1:3+n)';
                    [obj.params.L,~] = obj.getArcLength(X(1:3)',obj.params.kappa); 
    %                 break;
                    % Check if current optimized set is truely valid
                    obj.validate();
                    if ~obj.valid
                        % Replicate the most invalid segment
                        % Node indices are shifted for efficient segmentation
                        % Since this process will make the optimized parameters
                        % unstable, ArcFitBase optimization is done to
                        % stabilize parameters
                        obj.replicate();
                    else
                        disp('[Ending optimization...]')
                        break;
                    end
    %                 figure(100);
    %                 plot(obj.validity)
    
                end
            end
            % Save Optimization Results
            obj.opt.jac = jacobian;
            obj.opt.info = obj.opt.jac' * obj.opt.jac;
            obj.opt.cov = sparseinv(obj.opt.info);
        end
        
        %% Visualize: One Segment Optimization
        function visualize(obj)
            figure(1);
            p_est = plot(obj.points(1,:),obj.points(2,:),'r.'); hold on; grid on; axis equal;
%             plot(obj.matchedPoints(1,:),obj.matchedPoints(2,:),'b.');            
            n = length(obj.params.kappa);
            heading = obj.params.tau0;
            SegPoints = [obj.params.x0;
                         obj.params.y0];
            
            for i=1:n
                kappa = obj.params.kappa(i); L = obj.params.L(i);
                headingPrev = heading;
                heading = heading + kappa * L;
                headingCurr = heading;

                heading_ = linspace(headingPrev,headingCurr,1e3);
                addedSegPoints = SegPoints(:,end) + 1/kappa * [sin(heading_) - sin(headingPrev);
                                                               -cos(heading_) + cos(headingPrev)];
                SegPoints = [SegPoints addedSegPoints];
                
                p_node = plot(addedSegPoints(1,1),addedSegPoints(2,1),'co');
                plot(addedSegPoints(1,end),addedSegPoints(2,end),'co');

                idx = obj.params.bnds(i,2);
                plot(obj.points(1,idx),obj.points(2,idx),'gx');
            end
            p_lane = plot(SegPoints(1,:),SegPoints(2,:),'k-');            
            xlabel('Global X(m)'); ylabel('Global Y(m)');
            title('Optimized Vehicle Trajectory and Lane Segments');
            legend([p_est,p_lane,p_node], ...
                   'Input Lane Points', ...
                   'Optimized Arc Spline', ...
                   'Lane Sub-segment');
        end
        
        %% Create ArcFitBase (Test)
        function obj = TestArcFitBase(obj)
            ref_idxs = [1, obj.params.bnds(:,2)'];
            Points = obj.points(:,ref_idxs);
            bnds = obj.params.bnds;
%             Add Each Segment's mid points
            m = 8;
            for i=1:size(obj.params.bnds,1)
%                 m = 8 * (floor((bnds(i,2) - bnds(i,1))/100) + 1);
                idx = floor(linspace(bnds(i,1),bnds(i,2),m));
                A = unique(idx);
                if length(A) ~= length(idx)
                    disp(idx)
                    error('Repeated Idx')
                end
                % Check if there is any repeated value in idx
                Points = [Points, obj.points(:,idx(2:m-1))];
            end
            test = ArcFitBase(Points,obj.params,m-2);
            test.optimize();
            obj.params = test.params;
%             test = ArcFitBase2(obj.points,obj.params);
%             test.optimize();
%             obj.params = test.params;
        end

    end
    methods(Access = private)          
        %% NLS Cost Function Evaluation
        function res = cost_func(obj,x0)
            n = length(obj.params.kappa);
            initParams = x0(1:3);
            kappa = 1./x0(3+1:3+n);
            % Need to find arc length for each segment
            [Ls,Xcs] = obj.getArcLength(initParams,kappa);
            obj.opt.L = Ls;
%             error('1')
            ME_res = obj.CreateMEBlock(kappa,Xcs);
            AM_res = obj.CreateAMBlock(initParams,kappa,Ls);
            res = vertcat(ME_res,AM_res);
        end
        
        %% Compute Arc Length
        function [Ls, Xcs] = getArcLength(obj,initParams,kappa)
            bnds = obj.params.bnds;
            x0 = initParams(1); y0 = initParams(2); tau0 = initParams(3);
            Ls = zeros(1,size(bnds,1));
            node1 = [x0;y0];
            Xcs = zeros(2,size(bnds,1));
            Xcs(:,1) = node1 + 1/kappa(1) * [-sin(tau0);cos(tau0)];
            lb_idx = 1;
            lb_matched = node1;
            heading = tau0;

            for i=1:size(bnds,1)
                ub_idx = bnds(i,2);
                Point = obj.points(:,ub_idx);
                ang = atan2(Point(2) - Xcs(2,i),Point(1) - Xcs(1,i));
                ub_matched = Xcs(:,i) + 1/abs(kappa(i)) * [cos(ang);sin(ang)];
                Ls(i) = 1/abs(kappa(i)) * obj.getCenterAngle(lb_idx,ub_idx,lb_matched,ub_matched,Xcs(:,i));
                
                if i ~= size(bnds,1)
                    heading = heading + kappa(i) * Ls(i);
                    Xcs(:,i+1) = Xcs(:,i) + (1/kappa(i) - 1/kappa(i+1)) * [sin(heading); -cos(heading)];

                    lb_matched = ub_matched;
                    lb_idx = ub_idx;
                end
            end
        end

        %% Create Measurement Block
        function res = CreateMEBlock(obj,kappa,Xcs)
            blk_height = 2*size(obj.points,2);            
            res = zeros(blk_height,1);
            
            for i=1:size(obj.points,2)
                SegIdx = obj.assoc(i);
                Point = obj.points(:,i);
                cov = reshape(obj.covs(:,i),2,2);                
                res(2*i-1:2*i) = InvMahalanobis(obj.MEres(kappa,SegIdx,Point,Xcs),cov);
            end           
        end        

        %% Create Anchor Measurement Block
        function res = CreateAMBlock(obj,initParams,kappa,L)
            blk_height = 2*(size(obj.params.bnds,1)+1);
%             blk_height = 4;
            n = length(obj.params.kappa);
            res = zeros(blk_height,1);
            
            idxs = 0:1:n;
%             idxs = [0,n];
            for i=1:length(idxs)
                if i == 1 || i == length(idxs)
                    cov = diag([1e-5, 1e-5]);
                else 
%                     bnd_idx = obj.params.bnds(idxs(i))
                    cov = diag([1e-4,1e-4]);
                end
                res(2*i-1:2*i) = InvMahalanobis(obj.AMres(initParams,kappa,L,idxs(i)),cov);
            end
        end

        %% Anchor Measurement Residual
        function res = AMres(obj,initParams,kappa,L,SubSegIdx)
            nodePoints = obj.propNode(initParams,kappa,L);
            if SubSegIdx == 0   
                point = obj.points(:,1);
                X = nodePoints(:,1);
            else
                bnds = obj.params.bnds;
                idx = bnds(SubSegIdx,2);
                point = obj.points(:,idx);         
                X = nodePoints(:,SubSegIdx+1);    
            end                        
            res = X - point;
        end
        
        %% Jacobian Pattern for faster jacbian matrix computation
        function jac_pattern = getJacPattern(obj)
            n = length(obj.params.kappa);
            m = size(obj.points,2);
            blk_width = 3 + n;
%             blk_height = 2 * m + 4;
            blk_height = 2 * m + 2 * (n+1);
            jac_pattern = zeros(blk_height,blk_width);
            for i=1:m
                SegIdx = obj.assoc(i);
                jac_pattern(2*i-1:2*i,1:3+SegIdx) = ones(2,3+SegIdx);
            end
            
            jac_pattern(2*m+1:2*m+2,1:2) = eye(2);
%             jac_pattern(2*m+3:2*m+4,:) = ones(2,3+n);
            for i=1:n
                jac_pattern(2*m+2+2*i-1:2*m+2+2*i,1:3+i) = ones(2,3+i); 
            end
        end

        %% Data Association
        function obj = associate(obj)
            obj.assoc = zeros(1,size(obj.points,2));
            % If state idx is used, then association is fixed throughout
            % the whole optimization process
            bnds = obj.params.bnds;
            for i=1:size(bnds,1)
                lb = bnds(i,1); ub = bnds(i,2);
                if i~=1
                    obj.assoc(lb+1:ub) = i;
                else
                    obj.assoc(lb:ub) = i;
                end
            end
        end
        
        %% Validate current optimized parameter set
        function obj = validate(obj)
            cP = obj.propCenter([obj.params.x0,obj.params.y0,obj.params.tau0], ...
                                 obj.params.kappa, obj.params.L);
            
            chisq_thres = chi2inv(0.999,2); % 99.9% Reliability
            obj.validity = zeros(1,length(obj.params.kappa));
            obj.matchedPoints = zeros(2,size(obj.points,2));
            obj.Ndist = zeros(1,size(obj.points,2));
            for i=1:size(obj.points,2)
                SegIdx = obj.assoc(i);
                Xc = cP(:,SegIdx);
                Point = obj.points(:,i);
                ang = atan2(Point(2) - Xc(2),Point(1) - Xc(1));
                matchedPoint = Xc + 1/abs(obj.params.kappa(SegIdx)) * [cos(ang); sin(ang)];
                obj.matchedPoints(:,i) = matchedPoint;
                cov = reshape(obj.covs(:,i),2,2);
%                 cov = 0.1^2;
%                 R_pred = norm(Point - Xc);
%                 Ndist = (R_pred - 1/abs(obj.params.kappa(SegIdx)))' / cov * (R_pred - 1/abs(obj.params.kappa(SegIdx)));
                Ndist_ = (Point - matchedPoint)' / cov * (Point - matchedPoint);
                obj.Ndist(i) = Ndist_;
                if Ndist_ > chisq_thres
                    obj.validity(SegIdx) = obj.validity(SegIdx) + 1;
                end
            end
            
            disp('[Number of invalid apporoximations for each Sub-segment]')
            obj.valid = true;
            for i=1:length(obj.validity)
                if obj.validity(i) >= 3
                    obj.valid = false;
                end
                disp([' Sub-segment ',num2str(i),': ',num2str(obj.validity(i))])
            end
            if ~obj.valid
                disp('Current optimized arc parameter set is invalid, need to add more Sub-segments')
            else
                disp('All Sub-segments are valid!')
            end
        end
        
        %% Replicate most invalid Sub-segment
        function obj = replicate(obj)
            [~,SegIdx] = max(obj.validity);
            disp(['[Replicating Segment ',num2str(SegIdx),']'])
            n = length(obj.params.kappa);
            bnds = obj.params.bnds;
            kappa = obj.params.kappa;
            L = obj.params.L;

            % Test 
            % 1: Simply halve given idx bnds
            % 2: Pick idx with largest error --> if bnds is picked, then
            % simply halve idxs
%             mode = 2; % 2
%             if mode == 2
%                 idxs = find(obj.assoc == SegIdx);
%                 sampledNdist = obj.Ndist(idxs);
%                 [~,loc_idx] = max(sampledNdist);
%                 if loc_idx == 1 || loc_idx == length(sampledNdist)
%                     
%                 else
%                     idx1 = bnds(SegIdx,1) - 1 + loc_idx;
%                 end
%             end

            idx1 = floor(sum(bnds(SegIdx,:))/2);
            if SegIdx == 1                
                rem_bnds = obj.params.bnds(2:end,:);
                obj.params.bnds = [bnds(1,1), idx1;
                                   idx1, bnds(1,2);
                                   rem_bnds];

                
%                 if ~obj.validity(SegIdx+1)
%                     % Find maximum error idx for next segment
%                     idxs = find(obj.assoc == SegIdx+1);
%                     
%                     % Separate Next Segment if Next segment is also invalid
%                     sampledNdist = obj.Ndist(idxs);                
%                     [~,loc_idx] = max(sampledNdist);
%                     if loc_idx == 1 
%                         idx2 = bnds(SegIdx,2);
%                     else
%                         idx2 = floor((idx1 + bnds(SegIdx+1,2))/2);
% %                     else
% %                         idx2 = bnds(SegIdx+1,1) - 1 + loc_idx;
%                     end
%                 else
%                     % Next Segment is valid, do not alter
%                     idx2 = bnds(SegIdx,2);
%                 end
%                 
%                 % Modified version of index re-assignment
%                 obj.params.bnds = [bnds(SegIdx,1), idx1;
%                                    idx1, idx2;
%                                    idx2, bnds(SegIdx+1,2);
%                                    bnds(SegIdx+2:end,:)];                

                rem_kappa = obj.params.kappa(2:end);
                obj.params.kappa = [kappa(SegIdx), kappa(SegIdx), rem_kappa];
                
                % Used for ArcBaseFit
%                 L1 = 1/2 * L(SegIdx);
%                 L2 = 1/2 * (L1 + L(SegIdx+1));
%                 obj.params.L = [L1, L2, L2, L(SegIdx+2:end)];
            elseif SegIdx == n                
                rem_bnds = obj.params.bnds(1:end-1,:);
                obj.params.bnds = [rem_bnds;
                                   bnds(end,1), idx1;
                                   idx1, bnds(end,2)];

%                 % Find maximum error idx for previous segment
%                 idxs = find(obj.assoc == SegIdx-1);
%                 sampledNdist = obj.Ndist(idxs);
%                 [~,loc_idx] = max(sampledNdist);
%                 
%                 if ~obj.validity(SegIdx-1)
%                     if loc_idx == length(sampledNdist)
%                         idx2 = bnds(SegIdx,1);
%                     else
%                         % If largest error occurs at 
%                         idx2 = floor((idx1 + bnds(SegIdx-1,1))/2);
% %                     else
% %                         idx2 = bnds(SegIdx-1,1) - 1 + loc_idx;
%                     end
%                 else
%                     idx2 = bnds(SegIdx,1);
%                 end
%                 obj.params.bnds = [bnds(1:SegIdx-2,:);
%                                    bnds(SegIdx-1,1), idx2;
%                                    idx2, idx1;
%                                    idx1, bnds(SegIdx,2)];
                    

                rem_kappa = obj.params.kappa(1:end-1);
                obj.params.kappa = [rem_kappa, kappa(SegIdx), kappa(SegIdx)];
                
%                 L1 = 1/2 * L(SegIdx);
%                 L2 = 1/2 * (L1 + L(SegIdx-1));
%                 obj.params.L = [L(1:SegIdx-2), L2, L2, L1];                
            else
                rem_bndsP = obj.params.bnds(1:SegIdx-1,:);
                rem_bndsN = obj.params.bnds(SegIdx+1:end,:);
                obj.params.bnds = [rem_bndsP;
                                   bnds(SegIdx,1), idx1;
                                   idx1, bnds(SegIdx,2);
                                   rem_bndsN];

%                 % Find maximum error idx for previous segment
%                 idxsP = find(obj.assoc == SegIdx-1);
%                 sampledNdistP = obj.Ndist(idxsP);
%                 [~,loc_idxP] = max(sampledNdistP);
%                 
%                 if ~obj.validity(SegIdx-1)
%                     if loc_idxP == length(sampledNdistP)
%                         idxP = bnds(SegIdx,1);
%                     else
%                         idxP =  floor((idx1 + bnds(SegIdx-1,1))/2);
% %                     else
% %                         idxP = bnds(SegIdx-1,1) - 1 + loc_idxP;
%                     end
%                 else
%                     idxP = bnds(SegIdx,1);
%                 end
%                 
%                 % Find maximum error idx for next segment
%                 idxsN = find(obj.assoc == SegIdx+1);
%                 sampledNdistN = obj.Ndist(idxsN);
%                 [~,loc_idxN] = max(sampledNdistN);
%                 if loc_idxN == 1 
%                     idxN = bnds(SegIdx,2);
%                 else                   
%                     idxN = floor((idx1 + bnds(SegIdx+1,2))/2);
% %                 else
% %                     idxN = bnds(SegIdx+1,1) - 1 + loc_idxN;
%                 end
% %                 if ~obj.validity(SegIdx+1)
% %                     
% %                 else
% %                     idxN = bnds(SegIdx,2);
% %                 end
%                 
%                 obj.params.bnds = [bnds(1:SegIdx-2,:);
%                                    bnds(SegIdx-1,1), idxP;
%                                    idxP, idx1;
%                                    idx1, idxN;
%                                    idxN, bnds(SegIdx+1,2);
%                                    bnds(SegIdx+2:end,:)];

                rem_kappaP = obj.params.kappa(1:SegIdx-1);
                rem_kappaN = obj.params.kappa(SegIdx+1:end);
                obj.params.kappa = [rem_kappaP, kappa(SegIdx), kappa(SegIdx), rem_kappaN];
                
%                 L1 = 1/2 * L(SegIdx);
%                 LP = 1/2 * (L1 + 1/2 * L(SegIdx-1));
%                 LN = 1/2 * (L1 + 1/2 * L(SegIdx+1));
% 
%                 obj.params.L = [L(1:SegIdx-2), LP, LP, LN, LN, L(SegIdx+2:end)];
            end
            obj.params.L = obj.getInitArcLength();
        end
        
        %% Compute Arc Length
        function theta = getCenterAngle(obj,lb_idx,ub_idx,lb_matched,ub_matched,Xc)
            Point = obj.points(:,floor((lb_idx + ub_idx)/2));
            ang = atan2(Point(2) - Xc(2),Point(1) - Xc(1));
            TestPoint = Xc + 1e-6 * [cos(ang); sin(ang)];

            a = norm(lb_matched - Xc);
            b = norm(ub_matched - Xc);
            c = norm(lb_matched - ub_matched);
            theta = acos((a^2 + b^2 - c^2)/(2*a*b));
            
            X = [lb_matched(1),ub_matched(1),Xc(1)];
            Y = [lb_matched(2),ub_matched(2),Xc(2)];
            if ~inpolygon(TestPoint(1),TestPoint(2),X,Y)
                theta = 2*pi - theta;
            end
        end

        %% Precompute Measurement Jacobian for Chain Rule (Deprecated)
        function obj = precomputeMEJac(obj)
            % Iteratively pre compute jacobian terms for fast jacobian
            % computation
            % Computes Jacobian of all parameters w.r.t. Xc, Yc variables
            % (Xc, Yc) are center of arc segments 
            %
            % Implemented by JinHwan Jeon, 2022
            %
            % Not used currently: deprecated

            n = length(obj.params.kappa);           
            obj.precomp_jac.Xc = zeros(n,2*n+3);
            obj.precomp_jac.Yc = zeros(n,2*n+3);
            
            kappa = obj.params.kappa;
            L = obj.params.L;
            heading = obj.params.tau0;            

            for i=1:n
                % I : Index of Matched Sub-segment index
                % J : Index of Sub-segment parameter of interest

                if i == 1
                    obj.precomp_jac.Xc(1,1) = 1;
                    obj.precomp_jac.Xc(1,3) = -1/kappa(1) * cos(heading);
                    obj.precomp_jac.Xc(1,4) = 1/kappa(1)^2 * sin(heading);

                    obj.precomp_jac.Yc(1,2) = 1;
                    obj.precomp_jac.Yc(1,3) = -1/kappa(1) * sin(heading);
                    obj.precomp_jac.Yc(1,4) = -1/kappa(1)^2 * cos(heading);
                else
                    obj.precomp_jac.Xc(i,1) = obj.precomp_jac.Xc(i-1,1);
                    obj.precomp_jac.Xc(i,3) = obj.precomp_jac.Xc(i-1,3) + (1/kappa(i-1) - 1/kappa(i)) * cos(heading);

                    obj.precomp_jac.Yc(i,2) = obj.precomp_jac.Yc(i-1,2);
                    obj.precomp_jac.Yc(i,3) = obj.precomp_jac.Yc(i-1,3) + (1/kappa(i-1) - 1/kappa(i)) * sin(heading);

                    for j=1:i
                        % Kappa
                        if j == i-1
                            obj.precomp_jac.Xc(i,3+i-1) = obj.precomp_jac.Xc(i-1,3+i-1) + L(i-1) * (1/kappa(i-1) - 1/kappa(i)) * cos(heading) - 1/kappa(i-1)^2 * sin(heading);
                            obj.precomp_jac.Yc(i,3+i-1) = obj.precomp_jac.Yc(i-1,3+i-1) + L(i-1) * (1/kappa(i-1) - 1/kappa(i)) * sin(heading) + 1/kappa(i-1)^2 * cos(heading);
                        elseif j == i
                            obj.precomp_jac.Xc(i,3+i) = 1/kappa(i)^2 * sin(heading);
                            obj.precomp_jac.Yc(i,3+i) = -1/kappa(i)^2 * cos(heading);
                        else
                            obj.precomp_jac.Xc(i,3+j) = obj.precomp_jac.Xc(i-1,3+j) + L(j) * (1/kappa(i-1) - 1/kappa(i)) * cos(heading);
                            obj.precomp_jac.Yc(i,3+j) = obj.precomp_jac.Yc(i-1,3+j) + L(j) * (1/kappa(i-1) - 1/kappa(i)) * sin(heading);
                        end
                        % L
                        if j ~= i
                            obj.precomp_jac.Xc(i,3+n+j) = obj.precomp_jac.Xc(i-1,3+n+j) + kappa(j) * (1/kappa(i-1) - 1/kappa(i)) * cos(heading);
                            obj.precomp_jac.Yc(i,3+n+j) = obj.precomp_jac.Yc(i-1,3+n+j) + kappa(j) * (1/kappa(i-1) - 1/kappa(i)) * sin(heading);
                        end
                    end                    
                end

                heading = heading + kappa(i) * L(i);
            end
        end
        
        %% Precompute Anchoring Model Jacobian (Deprecated)
        function obj = precomputeAMJac(obj)
            % Iteratively pre compute jacobian terms for fast jacobian
            % computation
            % Computes Jacobian of all parameters w.r.t. Xn, Yn variables
            % (Xc, Yc) are node of arc segments 
            %
            % Implemented by JinHwan Jeon, 2022
            %
            % Not used currently: deprecated

            heading = obj.params.tau0;
            kappa = obj.params.kappa; L = obj.params.L;
            n = length(kappa);
            obj.precomp_jac.Xn = zeros(n,2*n+3);
            obj.precomp_jac.Yn = zeros(n,2*n+3);
            
            for i=1:n
                if i == 1 % x1, y1 : 1 step propagated point
                    obj.precomp_jac.Xn(1,1) = 1;
                    obj.precomp_jac.Xn(1,3) = 1/kappa(i) * (cos(heading + kappa(i) * L(i)) - cos(heading));
                    obj.precomp_jac.Xn(1,4) = L(i)/kappa(i) * cos(heading + kappa(i) * L(i)) - 1/kappa(i)^2 * (sin(heading + kappa(i) * L(i)) - sin(heading));
                    obj.precomp_jac.Xn(1,3+n+1) = cos(heading + kappa(i) * L(i));

                    obj.precomp_jac.Yn(1,2) = 1;
                    obj.precomp_jac.Yn(1,3) = 1/kappa(i) * (sin(heading + kappa(i) * L(i)) - sin(heading));
                    obj.precomp_jac.Yn(1,4) = L(i)/kappa(i) * sin(heading + kappa(i) * L(i)) + 1/kappa(i)^2 * (cos(heading + kappa(i) * L(i)) - cos(heading));
                    obj.precomp_jac.Yn(1,3+n+1) = sin(heading + kappa(i) * L(i));
                else
                    obj.precomp_jac.Xn(i,1) = obj.precomp_jac.Xn(i-1,1);
                    obj.precomp_jac.Xn(i,3) = obj.precomp_jac.Xn(i-1,1) + 1/kappa(i) * (cos(heading + kappa(i) * L(i)) - cos(heading));

                    obj.precomp_jac.Yn(i,2) = obj.precomp_jac.Yn(i-1,2);
                    obj.precomp_jac.Yn(i,3) = obj.precomp_jac.Yn(i-1,3) + 1/kappa(i) * (sin(heading + kappa(i) * L(i)) - sin(heading));
                    
                    for j=1:i
                        if j ~= i
                            obj.precomp_jac.Xn(i,3+j) = obj.precomp_jac.Xn(i-1,3+j) + 1/kappa(i) * L(j) * (cos(heading + kappa(i) * L(i)) - cos(heading));
                            obj.precomp_jac.Xn(i,3+n+j) = obj.precomp_jac.Xn(i-1,3+n+j) + kappa(j)/kappa(i) * (cos(heading + kappa(i) * L(i)) - cos(heading));
                            
                            obj.precomp_jac.Yn(i,3+j) = obj.precomp_jac.Yn(i-1,3+j) + 1/kappa(i) * L(j) * (sin(heading + kappa(i) * L(i)) - sin(heading));
                            obj.precomp_jac.Yn(i,3+n+j) = obj.precomp_jac.Yn(i-1,3+n+j) + kappa(j)/kappa(i) * (sin(heading + kappa(i) * L(i)) - sin(heading));
                        else
                            obj.precomp_jac.Xn(i,3+j) = L(i)/kappa(i) * cos(heading + kappa(i) * L(i)) - 1/kappa(i)^2 * (sin(heading + kappa(i) * L(i)) - sin(heading));
                            obj.precomp_jac.Xn(i,3+n+j) = cos(heading + kappa(i) * L(i));

                            obj.precomp_jac.Yn(i,3+j) = L(i)/kappa(i) * sin(heading + kappa(i) * L(i)) + 1/kappa(i)^2 * (cos(heading + kappa(i) * L(i)) - cos(heading));
                            obj.precomp_jac.Yn(i,3+n+j) = sin(heading + kappa(i) * L(i));
                        end
                    end
                end
                
                heading = heading + kappa(i) * L(i);
            end

        end
        
        %% Compute Initial Arc Length values
        function L = getInitArcLength(obj)
            bnds = obj.params.bnds;
            L = [];
            for i=1:size(bnds,1)
                lb = bnds(i,1); ub = bnds(i,2);
                L_ = 0;
                for j=lb:ub-1
                    L_ = L_ + norm(obj.points(:,j+1) - obj.points(:,j));
                end
                L = [L, L_];
            end
        end

    end

    methods(Static)
        %% Arc Measurement Residual
        function res = MEres(kappa,SegIdx,Point,Xcs)
%             centerPoints = obj.propCenter(initParams,kappa,L);
            Xc = Xcs(:,SegIdx);
            ang = atan2(Point(2) - Xc(2),Point(1) - Xc(1));
            matchedPoint = Xc + 1/abs(kappa(SegIdx)) * [cos(ang); sin(ang)];
            res = (matchedPoint - Point);
%             res = sqrt((Xc - Point)' * (Xc - Point)) - abs(1/kappa(SegIdx));
        end

        %% Propagate Arc Center Points
        function centerPoints = propCenter(initParams,kappa,L)
            x0 = initParams(1); y0 = initParams(2); heading = initParams(3);
            
            for i=1:length(kappa)
                if i == 1
                    centerPoints = [x0 - 1/kappa(i) * sin(heading); y0 + 1/kappa(i) * cos(heading)];
                else
                    centerPoints = [centerPoints centerPoints(:,end) + (1/kappa(i-1) - 1/kappa(i)) * [sin(heading);-cos(heading)]];
                end
                heading = heading + kappa(i) * L(i);
            end
        end

        %% Propagate Arc Node Points
        function nodePoints = propNode(initParams,kappa,L)
            x0 = initParams(1); y0 = initParams(2); heading = initParams(3);            
            nodePoints = [x0; y0];
            
            for i=1:length(kappa)
                nodePoints = [nodePoints nodePoints(:,end) + 1/kappa(i) * [sin(heading + kappa(i) * L(i)) - sin(heading);
                                                                           -cos(heading + kappa(i) * L(i)) + cos(heading)]];
                heading = heading + kappa(i) * L(i);
            end
        end        
        
    end
end