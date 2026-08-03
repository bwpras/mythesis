function [refPhase, scores, report] = pick_reference_phase(TestBrake)
%PICK_REFERENCE_PHASE_STRICT  Choose a reference phase only if ALL expected
%BC and WV streams are valid (GPS ignored).
%
% Eligibility (per phase)
%   MBP: Time & Pressure nonempty, equal length, >= 10 samples
%   BC : #valid == nBC_expected, each has Time/Pressure nonempty,
%        SensorError == 0, BrakingAct == 1 (if field exists)
%   WV : #valid == nWV_expected, each has Time/Pressure nonempty,
%        WV_SensorError == 0
%
% Outputs
%   refPhase : index of chosen phase (NaN if none)
%   scores   : 100 for eligible, -Inf otherwise
%   report   : diagnostics

    N = numel(TestBrake);
    scores = -inf(N,1);

    % expected = max count observed across dataset
    nBC_expected = max(arrayfun(@(s) numel(getfield_safe(s,'BC',[])), TestBrake));
    nWV_expected = max(arrayfun(@(s) numel(getfield_safe(s,'WV',[])), TestBrake));

    blank = struct( ...
        'MBP_OK',false, ...
        'BC_valid',0,'BC_total',0,'BC_expected',nBC_expected,'BC_OK',false, ...
        'WV_valid',0,'WV_total',0,'WV_expected',nWV_expected,'WV_OK',false, ...
        'HasErrors',false);
    report = repmat(blank, N, 1);

    for i = 1:N
        S = TestBrake(i);

        % MBP check
        MBP_OK = has_nonempty_series(S,'MBP_Time','MBP_Pressure',10);

        % BC: SensorError==0 AND BrakingAct==1
        [BC_valid, BC_total] = count_valid_streams( ...
            getfield_safe(S,'BC',[]), ...
            'Time','Pressure','SensorError',0, 'BrakingAct',1);

        % WV: WV_SensorError==0
        [WV_valid, WV_total] = count_valid_streams( ...
            getfield_safe(S,'WV',[]), ...
            'Time','Pressure','WV_SensorError',0, '', 0);

        BC_OK = (BC_valid == nBC_expected && BC_total >= nBC_expected);
        WV_OK = (WV_valid == nWV_expected && WV_total >= nWV_expected);

        hasErr = any_true_field(S, {'SV_Error','UP_Error','EmergencyBrake'});

        if MBP_OK && BC_OK && WV_OK
            scores(i) = 100 - 10*hasErr;   % small penalty if those flags are set
        end

        report(i).MBP_OK   = MBP_OK;
        report(i).BC_valid = BC_valid; report(i).BC_total = BC_total; report(i).BC_OK = BC_OK;
        report(i).WV_valid = WV_valid; report(i).WV_total = WV_total; report(i).WV_OK = WV_OK;
        report(i).HasErrors = hasErr;
    end

    if any(isfinite(scores))
        [~, refPhase] = max(scores);
    else
        refPhase = NaN;
    end
end

% ===== helpers =====
function tf = has_nonempty_series(S, tField, pField, minLen)
    tf = false;
    if ~isfield(S,tField) || ~isfield(S,pField), return; end
    t = S.(tField); p = S.(pField);
    if isempty(t) || isempty(p), return; end
    tf = isvector(t) && isvector(p) && numel(t)==numel(p) && numel(t)>=minLen;
end

function val = getfield_safe(S, fld, defaultVal)
    if isfield(S,fld), val=S.(fld); else, val=defaultVal; end
end

function [nValid,nTotal] = count_valid_streams(A,tName,pName,reqField,reqVal,optField,optVal)
% Count streams with:
%   - nonempty Time & Pressure
%   - reqField == reqVal
%   - if optField~='', then optField == optVal when present
    if nargin<6 || isempty(optField), optField = ''; end
    if nargin<7, optVal = 0; end
    nValid=0; nTotal=0;
    if isempty(A) || ~isstruct(A), return; end
    nTotal = numel(A);
    for k=1:nTotal
        X = A(k);
        hasT = isfield(X,tName) && ~isempty(X.(tName));
        hasP = isfield(X,pName) && ~isempty(X.(pName));
        reqOK = isfield(X,reqField) && ~isempty(X.(reqField)) && all(X.(reqField)==reqVal);
        optOK = true;
        if ~isempty(optField)
            if isfield(X,optField) && ~isempty(X.(optField))
                optOK = all(X.(optField)==optVal);
            end
        end
        if hasT && hasP && reqOK && optOK
            nValid = nValid + 1;
        end
    end
end

function tf = any_true_field(S, fields)
    tf=false;
    for ii=1:numel(fields)
        f=fields{ii};
        if isfield(S,f) && ~isempty(S.(f)) && any(S.(f)~=0)
            tf=true; return;
        end
    end
end
