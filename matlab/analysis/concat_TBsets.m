function AllBrakes = concat_TBsets(TBsets_out_filtered, keepFields)
% CONCAT_TBSETS  Normalize struct arrays in TBsets_out_filtered, then concatenate into one table.
%
%   AllBrakes = concat_TBsets(TBsets_out_filtered, keepFields)
%
% Inputs
%   TBsets_out_filtered : 1xN cell; each cell is a struct array of braking phases (fields ⊆ keepFields)
%   keepFields          : cellstr; whitelist of fields to keep/order
%
% Output
%   AllBrakes           : table; rows = all phases across cells, sorted by PhaseIdx (if present)

    if nargin < 2 || isempty(keepFields)
        error('concat_TBsets:MissingKeepFields', 'keepFields must be provided.');
    end

    desiredOrder = keepFields;

    % ---------- 1) Infer type hints across all cells ----------
    typeHint = containers.Map('KeyType','char','ValueType','char');
    for c = 1:numel(TBsets_out_filtered)
        S = TBsets_out_filtered{c};
        if isempty(S) || ~isstruct(S), continue; end
        fn = fieldnames(S);
        for k = 1:numel(fn)
            f = fn{k};
            if ~isKey(typeHint, f)
                % find first non-empty value using cellfun on {S.(f)}
                vals = {S.(f)};
                idx  = find(~cellfun(@isempty, vals), 1, 'first');
                if ~isempty(idx)
                    val = vals{idx};
                    cls = class(val);
                    if ischar(val)
                        cls = 'string'; % promote char -> string
                    end
                    typeHint(f) = cls;
                end
            end
        end
    end

    % Fallback class for never-seen fields
    for k = 1:numel(desiredOrder)
        f = desiredOrder{k};
        if ~isKey(typeHint, f)
            if endsWith(f, "_time") || startsWith(f, "Start_") || startsWith(f, "End_")
                typeHint(f) = 'datetime';
            elseif endsWith(f, "_Error") || contains(f, "EmergencyBrake") || contains(f, "Brake_action")
                typeHint(f) = 'logical';
            elseif contains(f, "_ID")
                typeHint(f) = 'string';
            else
                typeHint(f) = 'double';
            end
        end
    end

    % ---------- 2) Normalize each struct array, convert to table ----------
    outTables = cell(1, numel(TBsets_out_filtered));
    tCount = 0;

    for c = 1:numel(TBsets_out_filtered)
        S = TBsets_out_filtered{c};
        if isempty(S) || ~isstruct(S), continue; end
        n = numel(S);

        % add missing fields from keepFields with defaults
        fnS = fieldnames(S);
        missingF = setdiff(desiredOrder, fnS, 'stable');
        for k = 1:numel(missingF)
            f   = missingF{k};
            cls = typeHint(f);
            def = localDefault(cls);
            [S(1:n).(f)] = deal(def);
        end

        % strip any extra fields not in keepFields
        extraF = setdiff(fieldnames(S), desiredOrder);
        if ~isempty(extraF)
            S = rmfield(S, extraF);
        end

        % reorder for readability
        S = orderfields(S, intersect(desiredOrder, fieldnames(S), 'stable'));

        % struct -> table
        T = struct2table(S, 'AsArray', true);

        % promote char vars to string for consistency
        varNames = T.Properties.VariableNames;
        for v = 1:numel(varNames)
            col = T.(varNames{v});
            if iscell(col) && ~isempty(col) && ischar(col{1})
                T.(varNames{v}) = string(col);
            elseif ischar(col)
                T.(varNames{v}) = string(col);
            end
        end

        % provenance
        T.SourceIdx = repmat(c, height(T), 1);

        tCount = tCount + 1;
        outTables{tCount} = T;
    end

    % drop empties and vcat
    if tCount == 0
        AllBrakes = table();
        return;
    end
    outTables = outTables(1:tCount);
    AllBrakes = vertcat(outTables{:});

    % ---------- 3) Sort by PhaseIdx (if present) ----------
    if any(strcmp('PhaseIdx', AllBrakes.Properties.VariableNames))
        try
            AllBrakes = sortrows(AllBrakes, 'PhaseIdx', 'MissingPlacement', 'last');
        catch
            key = AllBrakes.PhaseIdx;
            if ~isfloat(key); key = double(key); end
            key(isnan(key)) = inf;
            [~, ord] = sort(key);
            AllBrakes = AllBrakes(ord, :);
        end
    end

    % ---------- 4) Final column order ----------
    baseOrder = intersect(desiredOrder, AllBrakes.Properties.VariableNames, 'stable');
    others    = setdiff(AllBrakes.Properties.VariableNames, [baseOrder, {'SourceIdx'}], 'stable');
    finalOrd  = [baseOrder, others, {'SourceIdx'}];
    AllBrakes = AllBrakes(:, finalOrd);

end

% ========== Local helper ==========
function def = localDefault(cls)
% Return a scalar default by class name
    switch cls
        case 'datetime'
            def = NaT;
        case 'logical'
            def = false;
        case {'string','char'}
            def = "";
        otherwise
            % numeric or anything else -> NaN (double)
            def = NaN;
    end
end
