%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2015, 2600Hz, INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(wh_service_plan).

-export([fetch/2]).
-export([activation_charges/3]).
-export([create_items/3]).

-include("whistle_services.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Given a vendor database and service plan id, fetch the document.
%% Merge any plan overrides into the plan property.
%% @end
%%--------------------------------------------------------------------
-spec fetch(ne_binary(), ne_binary()) -> kzd_service_plan:api_doc().
fetch(PlanId, VendorId) ->
    VendorDb = wh_util:format_account_id(VendorId, 'encoded'),
    case couch_mgr:open_cache_doc(VendorDb, PlanId) of
        {'ok', ServicePlan} ->
            lager:debug("found service plan ~s/~s", [VendorDb, PlanId]),
            ServicePlan;
        {'error', _R} ->
            lager:debug("unable to open service plan ~s/~s: ~p", [VendorDb, PlanId, _R]),
            'undefined'
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec activation_charges(ne_binary(), ne_binary(), kzd_service_plan:doc()) -> float().
activation_charges(CategoryId, ItemId, ServicePlan) ->
    case kzd_service_plan:item_activation_charge(ServicePlan, CategoryId, ItemId) of
        'undefined' ->
            kzd_service_plan:category_activation_charge(ServicePlan, CategoryId, 0.0);
        Charge -> Charge
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec create_items(kzd_service_plan:doc(), wh_service_items:items(), kzd_services:doc()) ->
                          wh_service_items:items().
-spec create_items(kzd_service_plan:doc(), wh_service_items:items(), kzd_services:doc()
                   ,ne_binary(), ne_binary()
                  ) ->
                          wh_service_items:items().
create_items(ServicePlan, ServiceItems, ServicesJObj) ->
    Plans = [{CategoryId, ItemId}
             || CategoryId <- kzd_service_plan:categories(ServicePlan),
                ItemId <- kzd_service_plan:items(ServicePlan, CategoryId)
            ],
    lists:foldl(fun({CategoryId, ItemId}, SIs) ->
                        create_items(ServicePlan, SIs, ServicesJObj, CategoryId, ItemId)
                end
                ,ServiceItems
                ,Plans
               ).

create_items(ServicePlan, ServiceItems, ServicesJObj, CategoryId, ItemId) ->
    ItemPlan = kzd_service_plan:item(ServicePlan, CategoryId, ItemId),

    {Rate, Quantity} = get_rate_at_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj),
    lager:debug("for ~s/~s, found rate ~p for quantity ~p", [CategoryId, ItemId, Rate, Quantity]),

    Charge = activation_charges(CategoryId, ItemId, ServicePlan),
    Min = kzd_service_plan:item_minimum(ServicePlan, CategoryId, ItemId),

    %% allow service plans to re-map item names (IE: softphone items "as" sip_device)
    As = kzd_item_plan:masquerade_as(ItemPlan, ItemId),
    lager:debug("item ~s masquerades as ~s", [ItemId, As]),

    Routines = [fun(I) -> wh_service_item:set_category(CategoryId, I) end
                ,fun(I) -> wh_service_item:set_item(As, I) end
                ,fun(I) -> wh_service_item:set_quantity(Quantity, I) end
                ,fun(I) -> wh_service_item:set_rate(Rate, I) end
                ,fun(I) -> maybe_set_discounts(I, ItemPlan) end
                ,fun(I) -> wh_service_item:set_bookkeepers(bookkeeper_jobj(CategoryId, As, ServicePlan), I) end
                ,fun(I) -> wh_service_item:set_activation_charge(Charge, I) end
                ,fun(I) -> wh_service_item:set_minimum(Min, I) end
               ],
    ServiceItem = lists:foldl(fun(F, I) -> F(I) end
                              ,wh_service_items:find(CategoryId, As, ServiceItems)
                              ,Routines
                             ),
    wh_service_items:update(ServiceItem, ServiceItems).

-spec maybe_set_discounts(wh_service_item:item(), kzd_item_plan:doc()) ->
                                 wh_service_item:item().
maybe_set_discounts(Item, ItemPlan) ->
    lists:foldl(fun(F, I) -> F(I, ItemPlan) end
                ,Item
                ,[fun maybe_set_single_discount/2
                  ,fun maybe_set_cumulative_discount/2
                 ]
               ).

-spec maybe_set_single_discount(wh_service_item:item(), kzd_item_plan:doc()) ->
                                       wh_service_item:item().
maybe_set_single_discount(Item, ItemPlan) ->
    case kzd_item_plan:single_discount(ItemPlan) of
        'undefined' -> Item;
        SingleDiscount ->
            SingleRate = wh_json:get_float_value(<<"rate">>, SingleDiscount, wh_service_item:rate(Item)),
            lager:debug("setting single discount rate ~p", [SingleRate]),
            wh_service_item:set_single_discount_rate(SingleRate, Item)
    end.

-spec maybe_set_cumulative_discount(wh_service_item:item(), kzd_item_plan:doc()) ->
                                           wh_service_item:item().
maybe_set_cumulative_discount(Item, ItemPlan) ->
    case kzd_item_plan:cumulative_discount(ItemPlan) of
        'undefined' -> Item;
        CumulativeDiscount ->
            set_cumulative_discount(Item, CumulativeDiscount)
    end.

-spec set_cumulative_discount(wh_service_item:item(), wh_json:object()) ->
                                     wh_service_item:item().
set_cumulative_discount(Item, CumulativeDiscount) ->
    Quantity = wh_service_item:quantity(Item),

    CumulativeQuantity = cumulative_quantity(Item, CumulativeDiscount, Quantity),

    CumulativeRate = case get_quantity_rate(Quantity, CumulativeDiscount) of
                         'undefined' -> wh_service_item:rate(Item);
                         Else -> Else
                     end,

    lager:debug("setting cumulative discount ~p @ ~p", [CumulativeQuantity, CumulativeRate]),

    Item1 = wh_service_item:set_cumulative_discount(CumulativeQuantity, Item),
    wh_service_item:set_cumulative_discount_rate(CumulativeRate, Item1).

-spec cumulative_quantity(wh_service_item:item(), wh_json:object(), integer()) -> integer().
cumulative_quantity(Item, CumulativeDiscount, Quantity) ->
    case wh_json:get_integer_value(<<"maximum">>, CumulativeDiscount, 0) of
        Max when Max < Quantity ->
            lager:debug("item '~s/~s' quantity ~p exceeds cumulative discount max, using ~p"
                        ,[wh_service_item:category(Item)
                          ,wh_service_item:item(Item)
                          ,Quantity
                          ,Max
                         ]
                       ),
            Max;
        _ -> Quantity
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec bookkeeper_jobj(ne_binary(), ne_binary(), kzd_service_plan:doc()) -> wh_json:object().
bookkeeper_jobj(CategoryId, ItemId, ServicePlan) ->
    lists:foldl(fun(Bookkeeper, J) ->
                        Mapping = wh_json:get_value([CategoryId, ItemId]
                                                    ,kzd_service_plan:bookkeeper(ServicePlan, Bookkeeper)
                                                    ,wh_json:new()
                                                   ),
                        wh_json:set_value(Bookkeeper, Mapping, J)
                end
                ,wh_json:new()
                ,kzd_service_plan:bookkeeper_ids(ServicePlan)
               ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec get_rate_at_quantity(ne_binary(), ne_binary(), kzd_service_plan:doc(), kzd_services:doc()) ->
                                  {float(), integer()}.
get_rate_at_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj) ->
    Quantity = get_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj),
    case get_flat_rate(Quantity, ItemPlan) of
        'undefined' -> {get_quantity_rate(Quantity, ItemPlan), Quantity};
        FlatRate -> {FlatRate, 1}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If tiered flate rates are provided, find the value to use given the
%% current quantity.
%% @end
%%--------------------------------------------------------------------
-spec get_quantity(ne_binary(), ne_binary(), kzd_item_plan:doc(), kzd_services:doc()) -> integer().
get_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj) ->
    ItemQuantity = get_item_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj),
    case kzd_item_plan:minimum(ItemPlan) of
        Min when Min > ItemQuantity ->
            lager:debug("minimum '~s/~s' not met with ~p, enforcing quantity ~p"
                        ,[CategoryId, ItemId, ItemQuantity, Min]
                       ),
            Min;
        _ -> ItemQuantity
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If tiered flate rates are provided, find the value to use given the
%% current quantity.
%% @end
%%--------------------------------------------------------------------
-spec get_flat_rate(non_neg_integer(), kzd_item_plan:doc()) -> api_float().
get_flat_rate(Quantity, ItemPlan) ->
    Rates = kzd_item_plan:flat_rates(ItemPlan),
    L1 = [wh_util:to_integer(K) || K <- wh_json:get_keys(Rates)],
    case lists:dropwhile(fun(K) -> Quantity > K end, lists:sort(L1)) of
        [] -> 'undefined';
        Range ->
            wh_json:get_float_value(wh_util:to_binary(hd(Range)), Rates)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If tiered rates are provided, find the value to use given the current
%% quantity.  If no rates are viable attempt to use the "rate" property.
%% @end
%%--------------------------------------------------------------------
-spec get_quantity_rate(non_neg_integer(), kzd_item_plan:doc()) -> api_float().
get_quantity_rate(Quantity, ItemPlan) ->
    Rates = kzd_item_plan:rates(ItemPlan),
    L1 = [wh_util:to_integer(K) || K <- wh_json:get_keys(Rates)],
    case lists:dropwhile(fun(K) -> Quantity > K end, lists:sort(L1)) of
        [] ->
            kzd_item_plan:rate(ItemPlan);
        Range ->
            wh_json:get_float_value(wh_util:to_binary(hd(Range)), Rates)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get the item quantity, drawing solely from the provided account or
%% (when the service plan dictates) the summed (cascaded) decendants.
%% Also handle the special case were we should sum all items in a
%% given category, except a list of item names to ignore during
%% summation.
%% @end
%%--------------------------------------------------------------------
-spec get_item_quantity(ne_binary(), ne_binary(), kzd_item_plan:doc(), kzd_services:doc()) ->
                               integer().
-spec get_item_quantity(ne_binary(), ne_binary(), kzd_item_plan:doc(), kzd_services:doc(), ne_binary()) ->
                               integer().

get_item_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj) ->
    get_item_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj, kzd_service_plan:all_items_key()).

get_item_quantity(CategoryId, AllItems, ItemPlan, ServicesJObj, AllItems) ->
    Exceptions = kzd_item_plan:exceptions(ItemPlan),

    case kzd_item_plan:should_cascade(ItemPlan) of
        'false' ->
            wh_services:category_quantity(CategoryId, Exceptions, ServicesJObj, wh_json:new());
        'true' ->
            lager:debug("collecting '~s' as a cascaded sum", [CategoryId]),

            CascadeQuantities = cascade_quantities(CategoryId, 'undefined', ServicesJObj),
            CatQuantities = wh_json:get_json_value(CategoryId, CascadeQuantities, wh_json:new()),
            QtysMinusEx = wh_json:delete_keys(Exceptions, CatQuantities),

            CategoryQuantity = wh_services:category_quantity(CategoryId, Exceptions, ServicesJObj, wh_json:new()),

            wh_json:foldl(fun(_ItemId, ItemQuantity, Sum) ->
                                  ItemQuantity + Sum
                          end
                          ,CategoryQuantity
                          ,QtysMinusEx
                         )
    end;
get_item_quantity(CategoryId, ItemId, ItemPlan, ServicesJObj, _AllItems) ->
    case kzd_item_plan:should_cascade(ItemPlan) of
        'false' ->
            wh_services:quantity(CategoryId, ItemId, ServicesJObj, wh_json:new());
        'true' ->
            lager:debug("collecting '~s/~s' as a cascaded quantity", [CategoryId, ItemId]),
            CascadeQuantities = cascade_quantities(CategoryId, ItemId, ServicesJObj),

            %% Cascade quantity
            kzd_services:item_quantity(ServicesJObj, CategoryId, ItemId) +
                wh_json:get_integer_value([CategoryId, ItemId], CascadeQuantities, 0)
    end.

-spec cascade_quantities(ne_binary(), api_binary(), kzd_services:doc()) ->
                                wh_json:object().
cascade_quantities(CategoryId, ItemId, ServicesJObj) ->
    AccountId = wh_doc:account_id(ServicesJObj),
    IsReseller = kzd_services:is_reseller(ServicesJObj),

    wh_services:cascade_quantities(AccountId
                                   ,IsReseller
                                   ,cascade_quantities_keys(CategoryId, ItemId)
                                  ).

-spec cascade_quantities_keys(ne_binary(), api_binary()) -> ne_binaries().
cascade_quantities_keys(<<_/binary>> = CategoryId, 'undefined') ->
    [CategoryId];
cascade_quantities_keys(<<_/binary>> = CategoryId, ItemId) ->
    [CategoryId, ItemId].
